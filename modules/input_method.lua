--[[
require("modules.input_method").start({
    defaultSource = "org.fcitx.inputmethod.Fcitx5.zhHans",
    apps = {
        ["com.apple.Spotlight"] = "com.apple.keylayout.ABC",
        ["com.apple.Terminal"] = "com.apple.keylayout.ABC",
    },
    chromeAddressSource = "com.apple.keylayout.ABC", -- Chrome 地址栏获得焦点时使用英文
})
-- hs.keycodes.currentSourceID() 查看当前输入法 ID；需要辅助功能权限。
]]
local M = {}
local watcher, observer, inputTap, focusTimer, config, lastContext
local log = hs.logger.new("input_method", "warning")
local function focusedApp()
    -- 优先读取辅助功能焦点，失败时使用前台应用。
    local ok, app = pcall(function()
        local element = hs.axuielement.systemWideElement():attributeValue("AXFocusedApplication")
        return element and hs.application.applicationForPID(element:pid())
    end)
    return (ok and app) or hs.application.frontmostApplication()
end
local function apply(app, addressBar)
    local id = app:bundleID()
    local context = tostring(app:pid()) .. ":" .. (addressBar and "address" or "app")
    if context == lastContext then return end -- 同一页面允许用户手动切换，不持续抢回输入法。
    lastContext = context
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
    if addressBar then source = config.chromeAddressSource end
    if source and hs.keycodes.currentSourceID() ~= source then
        if not hs.keycodes.currentSourceID(source) then log.w("无法切换输入法：" .. source) end
    end
end
local function stopObserver()
    if observer then observer:stop(); observer = nil end
end
local function chromeFocus(app)
    local ok, address = pcall(function()
        local root = hs.axuielement.applicationElementForPID(app:pid())
        local element = root:attributeValue("AXFocusedUIElement")
        for _ = 1, 4 do
        if not element then return false end
        local role = element:attributeValue("AXRole")
        if role == "AXTextField" or role == "AXComboBox" or role == "AXTextArea" then
        for _, key in ipairs({ "AXIdentifier", "AXDescription", "AXTitle", "AXHelp", "AXPlaceholderValue" }) do
            local text = tostring(element:attributeValue(key) or ""):lower()
            if text:find("omnibox", 1, true) or text:find("address and search", 1, true)
                or text:find("地址和搜索", 1, true) or text:find("地址与搜索", 1, true)
                or text:find("地址栏", 1, true) or text:find("address bar", 1, true) then return true end
        end
        end
        element = element:attributeValue("AXParent")
        end
        return false
    end)
    if ok then apply(app, address) end
end
-- 等待 Chrome 完成焦点更新；只在事件发生后检查一次，不轮询。
local function scheduleChromeFocus()
    if focusTimer then focusTimer:stop() end
    focusTimer = hs.timer.doAfter(0.08, function()
        focusTimer = nil
        local app = hs.application.frontmostApplication()
        if app and app:bundleID() == "com.google.Chrome" then chromeFocus(app) end
    end)
end
local function activated(app)
    stopObserver()
    lastContext = nil
    app = app or focusedApp()
    if not app then return end
    if app:bundleID() ~= "com.google.Chrome" then apply(app); return end
    local ok, err = pcall(function()
        local root = hs.axuielement.applicationElementForPID(app:pid())
        -- Chromium 可能尚未向辅助功能客户端公开完整控件树。
        pcall(function() root:setAttributeValue("AXManualAccessibility", true) end)
        observer = hs.axuielement.observer.new(app:pid())
        observer:callback(function()
            local front = hs.application.frontmostApplication()
            if front and front:pid() == app:pid() then scheduleChromeFocus() end
        end)
        observer:addWatcher(root, "AXFocusedUIElementChanged")
        observer:start()
    end)
    if not ok then stopObserver(); log.w("无法监听 Chrome 地址栏：" .. tostring(err)) end
    chromeFocus(app)
    scheduleChromeFocus()
end
function M.stop()
    if inputTap then inputTap:stop(); inputTap = nil end
    if focusTimer then focusTimer:stop(); focusTimer = nil end
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
        apps = options.apps or {},
    }
    assert(type(config.defaultSource) == "string", "defaultSource 必须为 Source ID")
    assert(type(config.chromeAddressSource) == "string", "chromeAddressSource 必须为 Source ID")
    for _, source in pairs(config.apps) do assert(type(source) == "string", "应用规则需要 Source ID") end
    watcher = hs.application.watcher.new(function(_, event, app)
        if event == hs.application.watcher.activated then activated(app)
        elseif event == hs.application.watcher.deactivated then stopObserver() end
    end):start()
    local types = hs.eventtap.event.types
    inputTap = hs.eventtap.new({ types.leftMouseUp, types.keyUp }, function(event)
        local app = hs.application.frontmostApplication()
        if app and app:bundleID() == "com.google.Chrome" then
            local key = event:getKeyCode()
            if event:getType() == types.leftMouseUp or key == 48 or key == 36 or key == 53
                or (key == 37 and event:getFlags().cmd) then scheduleChromeFocus() end
        end
        return false
    end):start()
    activated()
    return M
end
return M
