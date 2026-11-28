--[[
require("modules.input_assistant").start({
    defaultSource = "org.fcitx.inputmethod.Fcitx5.zhHans",
    englishPunctuation = { -- 仅对列出的应用转换英文标点，支持 * 前缀匹配
        "com.microsoft.VSCode",
        "com.jetbrains.*",
    },
    appInputSources = { -- 按输入法分组，列出使用它的应用
        ["com.apple.keylayout.ABC"] = {
            "com.apple.Spotlight",
            "com.apple.Terminal",
        },
    },
    focusInputSources = { -- 按输入法分组，列出使用它的输入区域
        ["com.apple.keylayout.ABC"] = {
            "chromeAddress", -- Chrome 地址栏
            "vscodeConsolePanel", -- VS Code 控制台面板
        },
        ["org.fcitx.inputmethod.Fcitx5.zhHans"] = {
            "vscodeChat", -- VS Code ChatGPT/Codex 聊天输入框
        },
    },
})
-- hs.keycodes.currentSourceID() 查看当前输入法 ID；需要辅助功能权限。
]]
local M = {}
local DEFAULT_SOURCE = "org.fcitx.inputmethod.Fcitx5.zhHans"
M.installation = {
    title = "输入法规则说明",
    command = [[# 默认输入法用于未配置的应用。
# 应用名单填写 Bundle ID；支持 com.jetbrains.* 这样的前缀匹配。
# 英文标点只对名单中的软件生效，不改变当前输入法；- 和 = 保留候选翻页。
# 应用输入法、输入区域均按输入法 ID 分组，同一个应用或区域只放入一个分组。
# 未单独配置时，Chrome 地址栏和 VS Code 控制台面板使用 ABC；聊天输入框使用默认输入法。
# 所选输入法必须先在系统设置中启用；GUI 只读取列表，不切换输入法。]],
}
M.parameters = {
    {
        label = "基础设置",
        fields = { { key = "defaultSource", label = "默认输入法", default = DEFAULT_SOURCE, options = "inputSources" } },
    },
    {
        label = "英文标点",
        fields = { { key = "englishPunctuation", label = "使用英文标点的应用", default = {}, item = { options = "application" } } },
    },
    {
        key = "appInputSources", label = "应用输入法分组", control = "map", default = {}, itemLabel = "输入法分组",
        keyField = { label = "输入法", default = "", options = "inputSources" },
        valueField = { label = "应用 Bundle ID", default = {}, item = { options = "application" } },
    },
    {
        key = "focusInputSources", label = "输入区域分组", control = "map", default = {}, itemLabel = "输入法分组",
        keyField = { label = "输入法", default = "", options = "inputSources" },
        valueField = { label = "输入区域", default = {}, options = {
            { value = "chromeAddress", label = "Chrome 地址栏" },
            { value = "vscodeConsolePanel", label = "VS Code 控制台面板" },
            { value = "vscodeChat", label = "VS Code ChatGPT / Codex 聊天输入框" },
        } },
    },
}
local watcher, observer, retryTimer, refreshTimer, config, lastContext
local generation = 0
local log = hs.logger.new("input_assistant", "warning")
local punctuationTap, punctuationSymbols
local appRules
local punctuationKeys = {
    -- 不拦截未按 Shift 的 - 和 =，保留输入法候选翻页；_ 和 + 仍转换。
    [50] = { "`", "~" }, [27] = { nil, "_" }, [24] = { nil, "+" },
    [33] = { "[", "{" }, [30] = { "]", "}" }, [42] = { "\\", "|" },
    [41] = { ";", ":" }, [39] = { "'", '"' }, [43] = { ",", "<" },
    [47] = { ".", ">" }, [44] = { "/", "?" },
    [18] = { nil, "!" }, [19] = { nil, "@" }, [20] = { nil, "#" },
    [21] = { nil, "$" }, [23] = { nil, "%" }, [22] = { nil, "^" },
    [26] = { nil, "&" }, [28] = { nil, "*" }, [25] = { nil, "(" }, [29] = { nil, ")" },
}
local function enabledForApp()
    local app = hs.application.frontmostApplication()
    if not app then return false end
    local id = app:bundleID() or ""
    for _, bundle in ipairs(appRules) do
        if bundle == id then return true end
        if bundle:sub(-1) == "*" then
            local prefix = bundle:sub(1, -2)
            if id:sub(1, #prefix) == prefix then return true end
        end
    end
    return false
end
-- 仅在应用切换时更新；按软件决定是否转换，无需查询输入法或定时轮询。
local function updatePunctuation()
    if not punctuationTap then return end
    if enabledForApp() then
        punctuationTap:start()
    else
        punctuationTap:stop()
    end
end
local function startPunctuation(options)
    if options == false then return end
    options = options or {}
    assert(type(options) == "table", "englishPunctuation 必须为 Bundle ID 数组")
    appRules = {}
    for index, bundle in pairs(options) do
        if index ~= "symbols" then
        assert(type(index) == "number" and index >= 1 and index % 1 == 0
            and index <= #options and type(bundle) == "string" and bundle ~= "",
            "englishPunctuation 必须为 Bundle ID 数组")
        appRules[index] = bundle
        end
    end
    punctuationSymbols = options.symbols
    assert(punctuationSymbols == nil or type(punctuationSymbols) == "string", "symbols 必须为字符串")
    local injecting = false
    punctuationTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
        if injecting then return false end
        local flags = event:getFlags()
        if flags.cmd or flags.ctrl or flags.alt or flags.fn then return false end
        local pair = punctuationKeys[event:getKeyCode()]
        local symbol = pair and pair[flags.shift and 2 or 1]
        if not symbol or (punctuationSymbols and not punctuationSymbols:find(symbol, 1, true)) then return false end
        injecting = true
        local ok, err = pcall(hs.eventtap.keyStrokes, symbol)
        injecting = false
        if not ok then log.w("英文标点输入失败：" .. tostring(err)); return false end
        return true
    end)
    updatePunctuation()
end
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
    local source = config.appInputSources[id]
    if not source and id then
        local longest = 0
        for bundle, candidate in pairs(config.appInputSources) do
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
    updatePunctuation()
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
    if punctuationTap then punctuationTap:stop(); punctuationTap = nil end
    stopObserver()
    if watcher then watcher:stop(); watcher = nil end
    lastContext = nil
    return M
end
-- 启动时把按输入法分组的配置展开，事件处理仍直接查表。
local function expandSources(groups, name, allowed)
    assert(groups == nil or type(groups) == "table", name .. " 必须按输入法 ID 分组")
    local result = {}
    for source, targets in pairs(groups or {}) do
        assert(type(source) == "string" and source ~= "" and type(targets) == "table",
            name .. " 需要输入法 ID 和目标数组")
        for index, target in pairs(targets) do
            assert(type(index) == "number" and index >= 1 and index % 1 == 0 and index <= #targets
                and type(target) == "string" and target ~= "", name .. " 的每组必须为目标数组")
            assert(not allowed or allowed[target], "未知输入区域：" .. target)
            assert(not result[target], name .. " 重复配置：" .. target)
            result[target] = source
        end
    end
    return result
end
function M.start(options)
    M.stop()
    options = options or {}
    local focusSources = expandSources(options.focusInputSources, "focusInputSources", {
        chromeAddress = true, vscodeConsolePanel = true, vscodeChat = true,
    })
    local appSources = expandSources(options.appInputSources, "appInputSources")
    config = {
        defaultSource = options.defaultSource or DEFAULT_SOURCE,
        appInputSources = appSources,
        focusInputSources = {
            chromeAddress = focusSources.chromeAddress or "com.apple.keylayout.ABC",
            vscodeConsolePanel = focusSources.vscodeConsolePanel or "com.apple.keylayout.ABC",
            vscodeChat = focusSources.vscodeChat or options.defaultSource or DEFAULT_SOURCE,
        },
    }
    assert(type(config.defaultSource) == "string", "defaultSource 必须为 Source ID")
    for name, source in pairs(config.focusInputSources) do
        assert(type(source) == "string", "focusInputSources." .. name .. " 必须为 Source ID")
    end
    for _, source in pairs(config.appInputSources) do assert(type(source) == "string", "应用规则需要 Source ID") end
    -- 仅保留与父级输入法不同的子规则，不修改用户传入的配置。
    config.childRules = {}
    for _, id in ipairs({ "com.google.Chrome", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders" }) do
        local parent = appSource(id)
        local rules = {}
        if id == "com.google.Chrome" then
            if config.focusInputSources.chromeAddress ~= parent then rules.address = config.focusInputSources.chromeAddress end
        else
            if config.focusInputSources.vscodeConsolePanel ~= parent then rules.panel = config.focusInputSources.vscodeConsolePanel end
            if config.focusInputSources.vscodeChat ~= parent then rules.chat = config.focusInputSources.vscodeChat end
        end
        config.childRules[id] = rules
    end
    startPunctuation(options.englishPunctuation)
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
