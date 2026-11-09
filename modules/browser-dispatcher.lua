--[[
-- 将以下配置放在 init.lua 中；rules 从上到下匹配，首条命中后执行。
-- 未匹配链接使用 browsers 和 profiles 的第一项。
require("modules.browser-dispatcher").start({
    browsers = { "chrome", "edge", "safari", "firefox" }, -- 可选浏览器及显示顺序，第一项为默认
    profiles = { "Default", "Profile 1" }, -- Chrome/Edge 使用目录名；Firefox 使用 about:profiles 中的名称
    logLevel = "info", -- 可省略；调试时改为 "debug"
    rules = {
        -- "choose"：先从 browsers 选择浏览器，再从 profiles 选择 Profile。
        -- Safari 直接打开，忽略 profile。
        {
            urls = "www.jlc.com/newOrder", -- 自动匹配 HTTP/HTTPS、子路径、查询参数和锚点
            browser = "choose",
            profile = "choose",
        },
        -- 省略 browser / profile：分别使用全局数组第一项，不弹窗。
        {
            urls = "example.com/default",
        },
        -- 数组：仅从本条规则的自定义选项中选择，无需出现在全局数组里。
        {
            urls = { "example.com/order", "example.org/order" }, -- 多个地址任意一个命中即可
            browser = { "chrome", "edge", "safari", "firefox" },
            profile = { "Default", "Profile 133" },
        },
        -- 字符串：固定使用指定浏览器和 Profile，不弹窗。
        {
            urls = "example.com/work",
            browser = "edge",
            profile = "Profile 1",
        },
        -- patterns：高级 Lua 模式（非标准正则）；urls / patterns 均支持字符串或数组。
        -- 两个字段可同时配置，任意一项命中即可；此处匹配 /items/ 后的纯数字路径。
        {
            patterns = { "^https?://example%.com/items/%d+$" },
            browser = "firefox",
            profile = "default-release",
        },
        -- apps 使用来源应用名称（非 Bundle ID），可填字符串或数组，精确匹配。
        -- 只写 apps 时匹配这些应用打开的所有链接；也可加 urls / patterns 限定网址。
        -- 放在更具体的网址规则之后，避免优先拦截这些网址。
        {
            apps = { "WeChat", "Slack" },
            browser = "choose",
            profile = "choose",
        },
        -- browser 也支持浏览器 Bundle ID；显式写协议（如 https://apple.com）则只匹配该协议。
        {
            urls = "apple.com",
            browser = "com.apple.Safari",
        },
    },
})
]]
local M = {}
local dispatcher, profileChooser, browserChooser
local previousCallback, dispatchCallback

local profileBrowsers = {
    chrome = { id = "com.google.Chrome", app = "Google Chrome" },
    edge = { id = "com.microsoft.edgemac", app = "Microsoft Edge" },
    firefox = { id = "org.mozilla.firefox", app = "Firefox" },
}

local function openProfile(browser, profile)
    return function(url)
        local app = profileBrowsers[browser].app
        local args = { "-n", "-a", app, "--args" }
        if browser == "firefox" then
            -- Firefox 使用 Profile 名称。
            args[#args + 1] = "--no-remote"
            args[#args + 1] = "-P"
            args[#args + 1] = profile
            args[#args + 1] = "--new-tab"
        else
            args[#args + 1] = "--profile-directory=" .. profile
        end
        args[#args + 1] = url
        local task = hs.task.new("/usr/bin/open", function(code, _, stderr)
            if code ~= 0 then hs.printf("%s error: %s", app, stderr or "unknown") end
        end, args)
        if not task or not task:start() then hs.alert.show("无法启动 " .. app) end
    end
end

function M.stop()
    if browserChooser then
        browserChooser:hide()
        browserChooser = nil
    end
    if profileChooser then
        profileChooser:hide()
        profileChooser = nil
    end
    if dispatchCallback and hs.urlevent.httpCallback == dispatchCallback then
        hs.urlevent.httpCallback = previousCallback
    end
    previousCallback, dispatchCallback = nil, nil
    return M
end

function M.start(config)
    config = config or {}
    local profiles = config.profiles or { "Default", "Profile 1" }
    local browsers = config.browsers or { "chrome", "edge", "safari", "firefox" }
    local browserIDs = {
        chrome = "com.google.Chrome", edge = "com.microsoft.edgemac",
        safari = "com.apple.Safari", firefox = "org.mozilla.firefox",
    }
    local browserLabels = {
        chrome = "Google Chrome", edge = "Microsoft Edge", safari = "Safari", firefox = "Firefox",
    }
    local function validate(value, field)
        if type(value) == "table" then
            assert(#value > 0, field .. " 数组不能为空")
            for _, item in ipairs(value) do
                assert(type(item) == "string" and item ~= "", field .. " 数组必须包含非空字符串")
                if field == "browser" then
                    assert(browserIDs[item] or item:find(".", 1, true), "未知浏览器：" .. item)
                end
            end
        else
            assert(type(value) == "string" and value ~= "", field .. " 必须为字符串或数组")
            if field == "browser" then
                assert(browserIDs[value] or value:find(".", 1, true), "未知浏览器：" .. value)
            end
        end
    end
    assert(type(browsers) == "table" and type(profiles) == "table", "browsers / profiles 必须为数组")
    validate(browsers, "browser")
    validate(profiles, "profile")

    local function launch(handler, url)
        if type(handler) == "function" then
            handler(url)
        else
            hs.application.launchOrFocusByBundleID(handler)
            hs.urlevent.openURLWithBundle(url, handler)
        end
    end

    local function resolve(browser, profile)
        if browser == "choose" then browser = browsers end
        if profile == "choose" then profile = profiles end
        browser = browser or browsers[1]
        profile = profile or profiles[1]
        validate(browser, "browser")
        validate(profile, "profile")
        if type(browser) == "table" then
            local choices = {}
            for _, item in ipairs(browser) do
                choices[#choices + 1] = { text = browserLabels[item] or item, browser = item }
            end
            return function(url)
                if browserChooser then browserChooser:hide() end
                browserChooser = hs.chooser.new(function(choice)
                    if choice then launch(resolve(choice.browser, profile), url) end
                end)
                browserChooser:placeholderText("选择浏览器")
                browserChooser:choices(choices)
                browserChooser:rows(math.min(#choices, 10))
                browserChooser:show()
            end
        end
        local bundleID = browserIDs[browser] or browser
        for name, info in pairs(profileBrowsers) do
            if bundleID == info.id then
                if type(profile) == "string" then return openProfile(name, profile) end
                local choices = {}
                for _, item in ipairs(profile) do
                    choices[#choices + 1] = { text = item, profile = item }
                end
                return function(url)
                    if profileChooser then profileChooser:hide() end
                    profileChooser = hs.chooser.new(function(choice)
                        if choice then openProfile(name, choice.profile)(url) end
                    end)
                    profileChooser:placeholderText("选择 " .. info.app .. " Profile")
                    profileChooser:choices(choices)
                    profileChooser:rows(math.min(#choices, 10))
                    profileChooser:show()
                end
            end
        end
        -- Safari 等浏览器忽略 profile，直接打开。
        return bundleID
    end

    local function entries(value, field)
        if value == nil then return {} end
        if type(value) == "string" then value = { value } end
        assert(type(value) == "table", field .. " 必须为字符串或数组")
        for _, entry in ipairs(value) do
            assert(type(entry) == "string" and entry ~= "", field .. " 不能包含空字符串")
        end
        return value
    end

    local function compilePatterns(rule)
        local result = {}
        for _, address in ipairs(entries(rule.urls, "urls")) do
            assert(not address:find("%s"), "匹配地址不能含空白字符")
            local scheme, rest = address:match("^(https?://)(.+)$")
            address = rest or address
            assert(not address:find("://", 1, true), "只支持 HTTP/HTTPS 地址")
            local prefix = "^" .. (scheme or "https?://")
                .. address:gsub("(%W)", "%%%1")
            result[#result + 1] = prefix .. "$"
            -- 限定地址边界，避免匹配到相似域名或 /newOrderOther。
            if not address:find("#", 1, true) then
                if address:find("?", 1, true) then
                    result[#result + 1] = prefix .. "[&#]"
                elseif address:sub(-1) == "/" then
                    result[#result + 1] = prefix
                else
                    result[#result + 1] = prefix .. "[/?#]"
                end
            end
        end
        for _, pattern in ipairs(entries(rule.patterns, "patterns")) do
            assert(pcall(string.match, "", pattern), "无效的 Lua 模式：" .. pattern)
            result[#result + 1] = pattern
        end
        if #result == 0 and rule.urls == nil and rule.patterns == nil and rule.apps ~= nil then
            result[1] = "^https?://"
        end
        assert(#result > 0, "规则至少需要配置一个 urls、patterns 或 apps")
        return result
    end

    local patterns = {}
    for _, rule in ipairs(config.rules or {}) do
        local apps
        if rule.apps ~= nil then
            apps = {}
            for _, app in ipairs(entries(rule.apps, "apps")) do
                apps[#apps + 1] = "^" .. app:gsub("(%W)", "%%%1") .. "$"
            end
            assert(#apps > 0, "apps 数组不能为空")
        end
        patterns[#patterns + 1] = {
            compilePatterns(rule), resolve(rule.browser, rule.profile), nil, apps,
        }
    end
    local defaultHandler = resolve(browsers[1])

    M.stop()
    hs.loadSpoon("URLDispatcher")
    dispatcher = spoon.URLDispatcher
    dispatcher.default_handler = defaultHandler
    dispatcher.url_patterns = patterns
    dispatcher.logger.setLogLevel(config.logLevel or "info")
    previousCallback = hs.urlevent.httpCallback
    dispatcher:start()
    dispatchCallback = hs.urlevent.httpCallback
    return M
end

return M
