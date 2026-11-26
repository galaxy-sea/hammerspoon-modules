--[[
require("modules.input_method").start({
    defaultSource = "org.fcitx.inputmethod.Fcitx5.zhHans",
    apps = {
        ["com.apple.Spotlight"] = "com.apple.keylayout.ABC",
        ["com.apple.Terminal"] = "com.apple.keylayout.ABC",
    },
    chromeAddressSource = "com.apple.keylayout.ABC", -- Chrome 地址栏获得焦点时使用英文
    vscodeConsolePanelSource = "com.apple.keylayout.ABC", -- VS Code 控制台面板输入法
    vscodeChatSource = "org.fcitx.inputmethod.Fcitx5.zhHans", -- VS Code ChatGPT/Codex 聊天输入框
})
-- hs.keycodes.currentSourceID() 查看当前输入法 ID；需要辅助功能权限。
]]
local M = {}
local watcher, observer, retryTimer, refreshTimer, config, lastContext
local generation = 0
local log = hs.logger.new("input_method", "warning")
local attributeCache
local NIL = {}
local function attribute(element, key)
    local cached = attributeCache and attributeCache[element]
    if cached and cached[key] ~= nil then
        if cached[key] == NIL then return nil end
        return cached[key]
    end
    local value = element:attributeValue(key)
    if attributeCache then
        cached = cached or {}
        attributeCache[element] = cached
        cached[key] = value == nil and NIL or value
    end
    return value
end
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
local function appSource(id)
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
    return source
end
local function apply(app, addressBar)
    local id = app:bundleID()
    local context = tostring(app:pid()) .. ":" .. (addressBar == "chat" and "chat" or (addressBar and "special" or "app"))
    if context == lastContext then return end -- 同一页面允许用户手动切换，不持续抢回输入法。
    local source = appSource(id)
    local rules = config.childRules[id] or {}
    if addressBar then
        local kind = addressBar == "chat" and "chat" or (isVSCode(id) and "panel" or "address")
        source = rules[kind] or source
    end
    local current = hs.keycodes.currentSourceID()
    if source and current ~= source then
        local switched = hs.keycodes.currentSourceID(source)
        if not switched then
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
        local role = attribute(element, "AXRole")
        if role == "AXWebArea" then return false end
        if role == "AXTextField" or role == "AXComboBox" or role == "AXTextArea" then
            for _, key in ipairs({ "AXDescription", "AXTitle", "AXIdentifier", "AXHelp", "AXPlaceholderValue" }) do
                local value = attribute(element, key)
                local text = type(value) == "string" and value:lower() or ""
                if text:find("omnibox", 1, true) or text:find("address and search", 1, true)
                    or text:find("address bar", 1, true) or text:find("地址和搜索", 1, true)
                    or text:find("地址与搜索", 1, true) or text:find("地址栏", 1, true)
                    or text:find("網址與搜尋", 1, true) then return true end
            end
        end
        element = attribute(element, "AXParent")
    end
    return false
end
-- 识别整个 VS Code Panel（终端、问题、输出、调试控制台及扩展面板）。
local function isVSCodePanel(element)
    local current = element
    for _ = 1, 24 do
        if not current then break end
        local classes = attribute(current, "AXDOMClassList")
        if type(classes) == "table" then
            local hasPart, hasPanel, hasComposite = false, false, false
            for _, class in ipairs(classes) do
                if class == "part" then hasPart = true end
                if class == "panel" then hasPanel = true end
                if class == "composite" then hasComposite = true end
                if class == "editor-group-container" or class == "auxiliarybar" or class == "sidebar" then
                    return false
                end
            end
            if hasPanel and (hasPart or hasComposite) then return true end
        end
        for _, key in ipairs({ "AXIdentifier", "AXDOMIdentifier" }) do
            local value = attribute(current, key)
            if value == "workbench.parts.panel" then return true end
            -- 到达编辑器或侧栏容器即可排除，无需继续查找。
            if value == "workbench.parts.editor" or value == "workbench.parts.sidebar"
                or value == "workbench.parts.auxiliarybar" then return false end
        end
        local role = attribute(current, "AXRole")
        if role == "AXWindow" or role == "AXApplication" then break end
        current = attribute(current, "AXParent")
    end
    return false
end
-- 根据实际采集的聊天输入控件识别，不依赖会随语言/会话变化的提示文字。
local function isChatInput(element)
    if attribute(element, "AXRole") ~= "AXTextArea" then return false end
    local proseMirror = false
    for _, class in ipairs(attribute(element, "AXDOMClassList") or {}) do
        if class == "ProseMirror" then proseMirror = true end
    end
    if not proseMirror then return false end
    local parent = attribute(element, "AXParent")
    for _ = 1, 4 do
        if not parent then break end
        for _, class in ipairs(attribute(parent, "AXDOMClassList") or {}) do
            if class:find("_ComposerLayoutBody_", 1, true) == 1 then return true end
        end
        parent = attribute(parent, "AXParent")
    end
    return false
end
local function activated(app)
    stopObserver()
    lastContext = nil
    app = app or focusedApp()
    if not app then return end
    local vscode = isVSCode(app:bundleID())
    local childRules = config.childRules[app:bundleID()]
    if not childRules or next(childRules) == nil then
        apply(app); return
    end
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
            if isCurrent() then refresh("AX_retry_after_1s") end
        end)
    end
    local function watch(element)
        for _, existing in ipairs(watched) do if existing == element then return true end end
        local count = 0
        for _, notification in ipairs({ "AXFocusedUIElementChanged", "AXWindowCreated", "AXFocusedWindowChanged", "AXSelectedChildrenChanged" }) do
            local ok = pcall(function() observer:addWatcher(element, notification) end)
            if ok then count = count + 1 end
        end
        if count > 0 then watched[#watched + 1] = element end
        return count > 0
    end
    refresh = function(trigger, eventElement)
        if not isCurrent() then return end
        attributeCache = {}
        local ok, ready = pcall(function()
            root = root or hs.axuielement.applicationElementForPID(app:pid())
            if not root then return false end
            if not observer then
                pcall(function() root:setAttributeValue("AXManualAccessibility", true) end)
            end
            local element
            if trigger == "AXFocusedUIElementChanged" and eventElement then
                local valid, focused = pcall(function() return attribute(eventElement, "AXFocused") end)
                if valid and focused == true then element = eventElement end
            end
            element = element or attribute(root, "AXFocusedUIElement")
            if not element then return false end
            local special
            if vscode then
                -- 已知聊天输入框先快速识别，避免先扫描整个 Panel 祖先链。
                if isChatInput(element) then special = "chat"
                elseif childRules.panel and isVSCodePanel(element) then special = true
                else special = false end
            else
                special = isAddressBar(element)
            end
            local transient = false
            if vscode and special == false then
                local role = attribute(element, "AXRole")
                transient = role ~= "AXTextArea" and role ~= "AXTextField" and role ~= "AXComboBox"
            end
            -- 标签、按钮及临时容器不代表用户已进入另一个输入区域。
            if not transient then apply(app, special) end
            if not observer or trigger == nil or trigger == "AXWindowCreated"
                or trigger == "AXFocusedWindowChanged" or trigger == "AX_retry_after_1s" then
            if not observer then
                observer = hs.axuielement.observer.new(app:pid())
                observer:callback(function(_, eventElement, notification)
                    if not isCurrent() then return end
                    if notification == "AXFocusedUIElementChanged" or notification == "AXSelectedChildrenChanged" then
                        lastContext = nil
                    end
                    refresh(notification, eventElement)
                    -- 仅窗口/标签变化补查一次，焦点事件不重复读取。
                    if notification ~= "AXFocusedUIElementChanged" then
                        if refreshTimer then refreshTimer:stop() end
                        refreshTimer = hs.timer.doAfter(0, function()
                            refreshTimer = nil
                            if isCurrent() then refresh("next_runloop_recheck") end
                        end)
                    end
                end)
            end
            local registered = watch(root)
            if trigger == nil or trigger == "AXWindowCreated" or trigger == "AXFocusedWindowChanged"
                or trigger == "AX_retry_after_1s" then
                local window = attribute(root, "AXFocusedWindow")
                if window then watch(window) end
            end
            observer:start()
                if not registered then return false end
            end
            return true
        end)
        attributeCache = nil
        if ok and ready then
            if retryTimer then retryTimer:stop(); retryTimer = nil end
        else
            if not ok then log.w("焦点读取/监听失败：" .. tostring(ready)) end
            retry()
        end
    end
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
        vscodeConsolePanelSource = options.vscodeConsolePanelSource or "com.apple.keylayout.ABC",
        vscodeChatSource = options.vscodeChatSource or options.defaultSource or "org.fcitx.inputmethod.Fcitx5.zhHans",
        apps = options.apps or {},
    }
    assert(type(config.defaultSource) == "string", "defaultSource 必须为 Source ID")
    assert(type(config.chromeAddressSource) == "string", "chromeAddressSource 必须为 Source ID")
    assert(type(config.vscodeConsolePanelSource) == "string", "vscodeConsolePanelSource 必须为 Source ID")
    assert(type(config.vscodeChatSource) == "string", "vscodeChatSource 必须为 Source ID")
    for _, source in pairs(config.apps) do assert(type(source) == "string", "应用规则需要 Source ID") end
    -- 仅保留与父级输入法不同的子规则，不修改用户传入的配置。
    config.childRules = {}
    for _, id in ipairs({ "com.google.Chrome", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders" }) do
        local parent = appSource(id)
        local rules = {}
        if id == "com.google.Chrome" then
            if config.chromeAddressSource ~= parent then rules.address = config.chromeAddressSource end
        else
            if config.vscodeConsolePanelSource ~= parent then rules.panel = config.vscodeConsolePanelSource end
            if config.vscodeChatSource ~= parent then rules.chat = config.vscodeChatSource end
        end
        config.childRules[id] = rules
    end
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
