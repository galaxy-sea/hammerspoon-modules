--[[
require("modules.input_method").start({
    defaultSource = "org.fcitx.inputmethod.Fcitx5.zhHans",
    apps = {
        ["com.apple.Spotlight"] = "com.apple.keylayout.ABC",
        ["com.apple.Terminal"] = "com.apple.keylayout.ABC",
    },
    chromeAddressSource = "com.apple.keylayout.ABC", -- Chrome 地址栏获得焦点时使用英文
    vscodeTerminalSource = "com.apple.keylayout.ABC", -- VS Code 集成终端获得焦点时使用英文
})
-- hs.keycodes.currentSourceID() 查看当前输入法 ID；需要辅助功能权限。
]]
local M = {}
local watcher, observer, retryTimer, refreshTimer, config, lastContext
local generation = 0
local log = hs.logger.new("input_method", "warning")
local function focusedApp()
    -- 优先读取辅助功能焦点，失败时使用前台应用。
    local ok, app = pcall(function()
        local element = hs.axuielement.systemWideElement():attributeValue("AXFocusedApplication")
        return element and hs.application.applicationForPID(element:pid())
    end)
    return (ok and app) or hs.application.frontmostApplication()
end
local function isVSCode(id)
    return id == "com.microsoft.VSCode" or id == "com.microsoft.VSCodeInsiders"
end
local function apply(app, addressBar)
    local id = app:bundleID()
    local context = tostring(app:pid()) .. ":" .. (addressBar and "address" or "app")
    if context == lastContext then return end -- 同一页面允许用户手动切换，不持续抢回输入法。
    local source = config.apps[id]
    if not source and id then
        local longest = 0
        for bundle, candidate in pairs(config.apps) do
            if bundle:sub(-1) == "*" then
                local prefix = bundle:sub(1, -2)
                if #prefix > longest and id:sub(1, #prefix) == prefix then
                    source, longest = candidate, #prefix
                end
            end
        end
    end
    source = source or config.defaultSource
    if id == "com.google.Chrome" then
        source = addressBar and config.chromeAddressSource or config.defaultSource
    elseif isVSCode(id) and addressBar then
        source = config.vscodeTerminalSource
    end
    if source and hs.keycodes.currentSourceID() ~= source then
        if not hs.keycodes.currentSourceID(source) then
            log.w("无法切换输入法：" .. source)
            return
        end
    end
    lastContext = context
end
local function stopObserver()
    generation = generation + 1
    if retryTimer then retryTimer:stop(); retryTimer = nil end
    if refreshTimer then refreshTimer:stop(); refreshTimer = nil end
    if observer then observer:stop(); observer = nil end
end

-- Chrome 各版本未必公开 AXDOMClassList，不能把它作为必需条件。
local function isAddressBar(element)
    for _ = 1, 4 do
        if not element then return false end
        local role = element:attributeValue("AXRole")
        if role == "AXWebArea" then return false end
        if role == "AXTextField" or role == "AXComboBox" or role == "AXTextArea" then
            for _, key in ipairs({ "AXIdentifier", "AXDescription", "AXTitle", "AXHelp", "AXPlaceholderValue" }) do
                local value = element:attributeValue(key)
                local text = type(value) == "string" and value:lower() or ""
                if text:find("omnibox", 1, true) or text:find("address and search", 1, true)
                    or text:find("address bar", 1, true) or text:find("地址和搜索", 1, true)
                    or text:find("地址与搜索", 1, true) or text:find("地址栏", 1, true)
                    or text:find("網址與搜尋", 1, true) then return true end
            end
        end
        element = element:attributeValue("AXParent")
    end
    return false
end
-- 只匹配终端输入控件，不根据窗口标题或整个终端面板判断。
local function isTerminalInput(element)
    local role = element:attributeValue("AXRole")
    if role ~= "AXTextArea" and role ~= "AXTextField" then return false end
    local classes = element:attributeValue("AXDOMClassList")
    if type(classes) == "table" then
        for _, class in ipairs(classes) do
            if class == "xterm-helper-textarea" then return true end
        end
    end
    for _, key in ipairs({ "AXIdentifier", "AXDescription", "AXTitle", "AXHelp" }) do
        local value = element:attributeValue(key)
        local text = type(value) == "string" and value:lower() or ""
        if text:find("xterm-helper-textarea", 1, true)
            or text:find("terminal input", 1, true) or text:find("终端输入", 1, true)
            or text:find("終端機輸入", 1, true) then return true end
    end
    return false
end
local function activated(app)
    stopObserver()
    lastContext = nil
    app = app or focusedApp()
    if not app then return end
    local vscode = isVSCode(app:bundleID())
    if app:bundleID() ~= "com.google.Chrome" and not vscode then apply(app); return end
    local currentGeneration = generation
    local watched, root = {}, nil
    local function isCurrent()
        local front = hs.application.frontmostApplication()
        return generation == currentGeneration and front and front:pid() == app:pid()
    end
    local refresh
    local function retry()
        if retryTimer or not isCurrent() then return end
        -- 仅在 AX 尚未就绪或注册失败时重试；成功后停止，不常驻轮询。
        retryTimer = hs.timer.doAfter(1, function()
            retryTimer = nil
            if isCurrent() then refresh() end
        end)
    end
    local function watch(element)
        for _, existing in ipairs(watched) do if existing == element then return true end end
        local count = 0
        for _, notification in ipairs({ "AXFocusedUIElementChanged", "AXTitleChanged", "AXWindowCreated", "AXFocusedWindowChanged", "AXSelectedChildrenChanged" }) do
            local ok = pcall(function() observer:addWatcher(element, notification) end)
            if ok then count = count + 1 end
        end
        if count > 0 then watched[#watched + 1] = element end
        return count > 0
    end
    refresh = function()
        if not isCurrent() then return end
        local ok, ready = pcall(function()
            root = root or hs.axuielement.applicationElementForPID(app:pid())
            if not root then return false end
            pcall(function() root:setAttributeValue("AXManualAccessibility", true) end)
            if not observer then
                observer = hs.axuielement.observer.new(app:pid())
                observer:callback(function(_, _, notification)
                    if not isCurrent() then return end
                    if notification == "AXFocusedUIElementChanged" or notification == "AXSelectedChildrenChanged" then
                        lastContext = nil
                    end
                    refresh()
                    -- 新标签事件可能先于焦点提交；下一轮主循环补查，不设置固定毫秒等待。
                    if refreshTimer then refreshTimer:stop() end
                    refreshTimer = hs.timer.doAfter(0, function()
                        refreshTimer = nil
                        if isCurrent() then refresh() end
                    end)
                end)
            end
            local registered = watch(root)
            for _, window in ipairs(root:attributeValue("AXWindows") or {}) do watch(window) end
            observer:start()
            local element = root:attributeValue("AXFocusedUIElement")
            if not element or not registered then return false end
            local special
            if vscode then special = isTerminalInput(element) else special = isAddressBar(element) end
            apply(app, special)
            return true
        end)
        if ok and ready then
            if retryTimer then retryTimer:stop(); retryTimer = nil end
        else
            if not ok then log.w("焦点读取/监听失败：" .. tostring(ready)) end
            retry()
        end
    end
    apply(app, false)
    refresh() -- 立即建立监听并检查，无固定延迟。
end
function M.stop()
    stopObserver()
    if watcher then watcher:stop(); watcher = nil end
    lastContext = nil
    return M
end
function M.start(options)
    M.stop()
    options = options or {}
    config = {
        defaultSource = options.defaultSource or "org.fcitx.inputmethod.Fcitx5.zhHans",
        chromeAddressSource = options.chromeAddressSource or "com.apple.keylayout.ABC",
        vscodeTerminalSource = options.vscodeTerminalSource or "com.apple.keylayout.ABC",
        apps = options.apps or {},
    }
    assert(type(config.defaultSource) == "string", "defaultSource 必须为 Source ID")
    assert(type(config.chromeAddressSource) == "string", "chromeAddressSource 必须为 Source ID")
    assert(type(config.vscodeTerminalSource) == "string", "vscodeTerminalSource 必须为 Source ID")
    for _, source in pairs(config.apps) do assert(type(source) == "string", "应用规则需要 Source ID") end
    watcher = hs.application.watcher.new(function(_, event)
        if event == hs.application.watcher.activated then
            -- 以当前前台应用为准；不让迟到的 deactivated 事件拆掉新监听。
            activated(hs.application.frontmostApplication())
        end
    end):start()
    activated()
    return M
end
return M
