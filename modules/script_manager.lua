--[[
local scripts = require("modules.script_manager").load() -- 仅启动脚本
require("modules.script_manager").start({ modules = scripts }) -- 可选 GUI
-- scripts 由 init.lua 传入已经独立启动的脚本及其配置。
-- 管理器的 start/stop 只创建或销毁界面，不启停其他脚本。
]]
local M = {}
local menu, contextMenu, view, bridge, registry, defaultScripts
local entries, order, overrides = {}, {}, {}
local settingsKey = "script_manager.settings.v1"
local htmlPath = debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") .. "script_manager.html"
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
local settingsPath = hs.configdir .. "/script_settings.json"
local function writeSettings(value)
    local data = assert(hs.json.encode(value, true), "配置编码失败")
    local temporary = settingsPath .. ".tmp"
    local file = assert(io.open(temporary, "w"))
    local written, writeError = file:write(data)
    local closed, closeError = file:close()
    if not written or not closed then
        os.remove(temporary)
        error(writeError or closeError or "配置写入失败")
    end
    local renamed, renameError = os.rename(temporary, settingsPath)
    if not renamed then os.remove(temporary); error(renameError or "配置保存失败") end
end
local function readSettings()
    local file, openError, code = io.open(settingsPath, "r")
    if file then
        local data = file:read("*a"); file:close()
        local value = hs.json.decode(data)
        assert(type(value) == "table", "script_settings.json 格式错误")
        return value
    end
    assert(code == 2, openError or "无法读取脚本配置")
    -- 首次使用新位置时迁移旧设置；写入成功后才移除旧偏好设置。
    local legacy = hs.settings.get(settingsKey)
    if type(legacy) == "table" then
        writeSettings(legacy)
        hs.settings.clear(settingsKey)
        return legacy
    end
    return {}
end
-- 检查实际来源，不把 require 的缓存当作文件仍存在；不使用轮询。
local function moduleExists(id)
    local name = "modules." .. id
    return package.preload[name] ~= nil or package.searchpath(name, package.path) ~= nil
end
-- 仅注册并独立启动脚本，不创建菜单或窗口；传入 {} 可从空列表开始手动注册。
function M.load(definitions)
    -- 各脚本独立启动；某个脚本启动失败不会阻止其他脚本。
    local scripts, registered = {}, {}
    local saved = readSettings()
    saved = type(saved) == "table" and saved or {}
    -- 手动注册：register("脚本文件名", { 配置 })；每个脚本直接调用自己的 start。
    local function register(definition, options)
        local script = type(definition) == "string" and { id = definition, options = options or {} } or copy(definition)
        assert(type(script) == "table" and type(script.id) == "string" and script.id:match("^[%w_]+$"), "脚本名称无效")
        assert(script.id ~= "script_manager" and not registered[script.id], "脚本重复注册：" .. script.id)
        for _, existing in ipairs(scripts) do assert(existing.id ~= script.id, "脚本重复注册：" .. script.id) end
        if not moduleExists(script.id) then return nil end -- 删除文件后自动忽略残留注册。
        script.title = script.title or script.id
        script.options = script.options or {}
        registered[script.id] = true
        scripts[#scripts + 1] = script
        script.defaults = script.defaults or { enabled = script.enabled ~= false, options = copy(script.options or {}) }
        script.enabled = script.enabled ~= false
        local setting = type(saved) == "table" and saved[script.id]
        if type(setting) == "table" and type(setting.enabled) == "boolean" and type(setting.options) == "table" then
            script.enabled, script.options = setting.enabled, copy(setting.options)
        end
        script.running = false
        if script.enabled then
            local ok, err = pcall(function()
                script.module = require("modules." .. script.id)
                script.module.start(copy(script.options))
                script.running = true
            end)
            if not ok then
                if script.module and script.module.stop then pcall(script.module.stop) end
                script.error = tostring(err)
                hs.printf("%s 启动失败：%s", script.title or script.id, script.error)
            end
        end
    end

    -- 默认配置缺失或无法读取时，仍允许通过已保存设置恢复脚本、打开 GUI。
    local discover = definitions == nil
    local recovering = false
    if definitions == nil then
        local exists = package.preload.config ~= nil or package.searchpath("config", package.path) ~= nil
        local ok, config
        if exists then ok, config = pcall(require, "config") end
        if ok and type(config) == "table" then
            definitions = config
        else
            definitions, recovering = {}, true
            hs.printf("config.lua %s；将使用本机已保存的脚本设置。", exists and "读取失败" or "不存在")
        end
    end
    assert(type(definitions) == "table", "脚本定义必须为列表")
    for _, definition in ipairs(definitions) do register(definition) end
    -- register("my_script", { intervalMinutes = 20 })

    -- GUI 注册的脚本也独立启动；手动注册的同名脚本优先，避免重复启动。
    local added = {}
    for id, setting in pairs(saved) do
        if type(id) == "string" and id ~= "script_manager" and id:match("^[%w_]+$")
            and type(setting) == "table" and type(setting.enabled) == "boolean" and type(setting.options) == "table"
            and (setting.registered == true or recovering) and not registered[id] then
            added[#added + 1] = id
        end
    end
    table.sort(added)
    for _, id in ipairs(added) do
        local setting = saved[id]
        register({ id = id, title = setting.title, description = setting.description,
            enabled = setting.enabled, options = setting.options, defaults = setting.defaults, registered = true })
    end

    -- 只在默认加载时扫描一次；新发现的脚本默认关闭，不执行其 start。
    if discover and hs.fs then
        local directory = htmlPath:match("^(.*[/\\])")
        local found = {}
        for file in hs.fs.dir(directory) do
            local id = file:match("^([%w_]+)%.lua$")
            if id and id ~= "script_manager" and not registered[id] then found[#found + 1] = id end
        end
        table.sort(found)
        for _, id in ipairs(found) do
            register({ id = id, enabled = false, options = {} })
        end
    end

    -- 如需在 init.lua 手动注册，可在加载 GUI 前调用 scripts.register(...)。
    scripts.register = register
    return scripts
end
local function validate(value, depth)
    depth = depth or 0
    assert(depth < 32, "配置层级过多")
    local kind = type(value)
    assert(kind == "table" or kind == "string" or kind == "number" or kind == "boolean", "配置仅支持文字、数字、开关和列表")
    if kind == "number" then assert(value == value and math.abs(value) < math.huge, "数字必须为有限值") end
    if kind == "table" then
        for key, item in pairs(value) do
            assert(type(key) == "string" or (type(key) == "number" and key >= 1 and key % 1 == 0), "配置键无效")
            validate(item, depth + 1)
        end
    end
end
-- 仅 GUI 读取参数描述，不调用脚本的 start；未声明参数的脚本保持原有编辑方式。
local parameterCache = {}
local function parametersFor(entry)
    if parameterCache[entry.id] == nil then
        local module = entry.module or package.loaded["modules." .. entry.id]
        if not module then
            local ok, loaded = pcall(require, "modules." .. entry.id)
            if ok then module = loaded end
        end
        parameterCache[entry.id] = type(module) == "table" and type(module.parameters) == "table" and module.parameters or false
    end
    return parameterCache[entry.id] and copy(parameterCache[entry.id]) or nil
end
local function applicationField(parameters, key)
    for _, parameter in ipairs(parameters or {}) do
        if parameter.key == key and parameter.options == "application" then return true end
        if parameter.fields and applicationField(parameter.fields, key) then return true end
    end
    return false
end
local function installationFor(entry)
    parametersFor(entry)
    local module = entry.module or package.loaded["modules." .. entry.id]
    return type(module) == "table" and type(module.installation) == "table" and copy(module.installation) or nil
end
local function snapshot()
    local result = {}
    for _, id in ipairs(order) do
        local entry = entries[id]
        if moduleExists(id) then
            result[#result + 1] = {
                id = id, title = entry.title, description = entry.description,
                enabled = entry.enabled, running = entry.running, error = entry.error,
                options = copy(entry.options), defaults = copy(entry.defaults), registered = entry.registered,
                parameters = parametersFor(entry), installation = installationFor(entry),
            }
        end
    end
    return result
end
local function stopEntry(entry)
    if entry.module then entry.module.stop() end
    entry.running = false
end
local function startEntry(entry, enabled, options)
    if not enabled then return end
    entry.module = entry.module or require("modules." .. entry.id)
    assert(type(entry.module.start) == "function" and type(entry.module.stop) == "function", "模块需要提供 start 和 stop 方法")
    entry.module.start(copy(options))
    entry.running = true
end
-- 保存前先应用；启动失败时清理部分资源，并恢复此前的启用状态与配置。
function M.apply(id, enabled, options)
    local entry = entries[id]
    if not entry or not moduleExists(id) then return false, "脚本已删除或不存在" end
    local valid, validationError = pcall(function()
        assert(type(enabled) == "boolean", "启用状态必须为布尔值")
        assert(type(options) == "table", "配置必须为对象")
        validate(options)
    end)
    if not valid then return false, tostring(validationError) end
    local oldOptions, oldEnabled = copy(entry.options), entry.enabled
    local ok, err = pcall(function()
        stopEntry(entry)
        startEntry(entry, enabled, options)
    end)
    if ok then
        local saved = copy(overrides)
        saved[id] = copy(saved[id] or {})
        saved[id].enabled, saved[id].options = enabled, copy(options)
        ok, err = pcall(writeSettings, saved)
        if ok then
            overrides = saved
            entry.enabled, entry.options, entry.error = enabled, copy(options), nil
            return true
        end
    end
    local cleaned, cleanupError = pcall(stopEntry, entry)
    local restored, restoreError = false, nil
    if cleaned then restored, restoreError = pcall(startEntry, entry, oldEnabled, oldOptions) end
    entry.error = tostring(err)
    if not cleaned then entry.error = entry.error .. "；清理失败：" .. tostring(cleanupError)
    elseif not restored then entry.error = entry.error .. "；恢复失败：" .. tostring(restoreError) end
    return false, entry.error
end
-- 只注册新脚本；已通过 init.lua 启动的脚本由 start({modules=...}) 接入，避免重复启动。
function M.register(definition)
    local entry
    local valid, err = pcall(function()
        assert(type(definition) == "table", "需要脚本注册信息")
        local id = definition.id
        assert(type(id) == "string" and id:match("^[%w_]+$") and id ~= "script_manager", "请输入 modules 目录中的脚本文件名，不含 .lua")
        assert(moduleExists(id), "脚本文件不存在，请先放入 modules 目录")
        assert(not entries[id], "这个脚本已注册")
        assert(package.loaded["modules." .. id] == nil, "脚本已加载，请在 init.lua 中注册并接入 GUI，避免重复启动")
        assert(definition.title == nil or (type(definition.title) == "string" and definition.title ~= ""), "显示名称不能为空")
        assert(definition.description == nil or type(definition.description) == "string", "说明必须为文字")
        assert(definition.enabled == nil or type(definition.enabled) == "boolean", "启用状态必须为布尔值")
        assert(definition.options == nil or type(definition.options) == "table", "配置必须为对象")
        validate(definition.options or {})
        entry = {
            id = id, title = definition.title or id, description = definition.description or "",
            enabled = definition.enabled ~= false, options = copy(definition.options or {}), running = false, registered = true,
        }
        entry.defaults = { enabled = entry.enabled, options = copy(entry.options) }
    end)
    if not valid then return false, tostring(err) end
    local loadedHere = false
    local ok, failure = pcall(function()
        entry.module = require("modules." .. entry.id)
        loadedHere = true
        assert(type(entry.module) == "table" and type(entry.module.start) == "function" and type(entry.module.stop) == "function",
            "脚本需要提供 start(options) 和 stop() 方法")
        startEntry(entry, entry.enabled, entry.options)
        local saved = copy(overrides)
        saved[entry.id] = {
            registered = true, title = entry.title, description = entry.description,
            enabled = entry.enabled, options = copy(entry.options), defaults = copy(entry.defaults),
        }
        writeSettings(saved)
        overrides = saved
    end)
    if not ok then
        local cleaned = true
        if type(entry.module) == "table" and type(entry.module.stop) == "function" then cleaned = pcall(stopEntry, entry) end
        if loadedHere and cleaned then package.loaded["modules." .. entry.id] = nil end
        return false, tostring(failure)
    end
    entries[entry.id], order[#order + 1] = entry, entry.id
    if registry then registry[#registry + 1] = entry end
    return true
end
function M.status()
    return snapshot()
end
-- 使用系统文件选择窗口挑选 .app，只读取 Bundle 信息，不启动所选软件。
function M.chooseApplication()
    local ok, files = pcall(hs.dialog.chooseFileOrFolder,
        "选择应用", "/Applications", true, false, false, { "app" }, true)
    if not ok then return nil, tostring(files) end
    local path = files and (files[1] or files["1"])
    if not path then return nil end
    local read, info = pcall(hs.application.infoForBundlePath, path)
    if not read or type(info) ~= "table" or type(info.CFBundleIdentifier) ~= "string" or info.CFBundleIdentifier == "" then
        return nil, "无法读取所选应用的 Bundle ID，请重新选择 .app 文件。"
    end
    return { id = info.CFBundleIdentifier, name = info.CFBundleDisplayName or info.CFBundleName or path:match("([^/]+)%.app$") or info.CFBundleIdentifier }
end
-- 只读取系统已启用的输入源；不注册输入法回调、不切换输入法。
function M.inputSources()
    local result, seen = {}, {}
    for _, getter in ipairs({ hs.keycodes.layouts, hs.keycodes.methods }) do
        local ok, ids = pcall(getter, true)
        local named, names = pcall(getter, false)
        if ok and type(ids) == "table" then
            for index, id in ipairs(ids) do
                if type(id) == "string" and not seen[id] then
                    seen[id] = true
                    local name = named and type(names) == "table" and names[index]
                    result[#result + 1] = { value = id, label = type(name) == "string" and name or id }
                end
            end
        end
    end
    return result
end
local function publish(message, success, savedID)
    if not view then return end
    local payload = hs.json.encode({ modules = M.status(), message = message or "", success = success ~= false, savedID = savedID })
    view:evaluateJavaScript("window.receiveState(" .. payload .. ")")
end
function M.show()
    if view then view:show():bringToFront(); return M end
    local file = assert(io.open(htmlPath, "r"))
    local html = file:read("*a"); file:close()
    bridge = hs.webview.usercontent.new("scriptManager")
    bridge:setCallback(function(message)
        local body = message.body
        if type(body) ~= "table" then return end
        if body.action == "ready" then publish()
        elseif body.action == "options" and body.source == "inputSources" then
            local result = { source = body.source, options = M.inputSources() }
            if view then view:evaluateJavaScript("window.receiveOptions(" .. hs.json.encode(result) .. ")") end
        elseif body.action == "chooseApplication" then
            if entries[body.id] and (type(body.request) == "string" or (type(body.key) == "string" and applicationField(parametersFor(entries[body.id]), body.key))) then
                local app, err = M.chooseApplication()
                if view then
                    local result = { id = body.id, key = body.key, request = body.request, application = app, error = err }
                    view:evaluateJavaScript("window.receiveApplication(" .. hs.json.encode(result) .. ")")
                end
            end
        elseif body.action == "save" then
            local ok, err = M.apply(body.id, body.enabled, body.options)
            publish(ok and "已保存并应用" or ("未保存：" .. tostring(err)), ok, ok and body.id or nil)
        end
    end)
    local frame = hs.screen.mainScreen():frame()
    local w, h = math.min(1020, frame.w - 40), math.min(760, frame.h - 40)
    view = hs.webview.new({ x = frame.x + (frame.w - w) / 2, y = frame.y + (frame.h - h) / 2, w = w, h = h },
        { javaScriptCanOpenWindowsAutomatically = false }, bridge)
        :windowStyle({ "titled", "closable", "resizable", "miniaturizable", "fullSizeContentView" })
        :transparent(false)
        :windowTitle("小脚本设置"):allowTextEntry(true):deleteOnClose(true)
    view:windowCallback(function(action)
        if action == "closing" then view, bridge = nil, nil end
    end)
    view:html(html):show():bringToFront()
    return M
end
function M.stop()
    if view then view:delete(); view, bridge = nil, nil end
    if menu then menu:delete(); menu = nil end
    if contextMenu then contextMenu:delete(); contextMenu = nil end
    entries, order, registry = {}, {}, nil
    return M
end
function M.start(options)
    options = options or {}
    assert(type(options) == "table", "配置必须为对象")
    local modules = options.modules or registry or defaultScripts
    if not modules then
        modules = M.load()
        defaultScripts = modules
    end
    assert(type(modules) == "table", "需要传入独立脚本列表 modules")
    M.stop()
    local saved = readSettings()
    overrides = type(saved) == "table" and saved or {}
    registry = modules
    for index, item in ipairs(registry) do
        assert(type(item.id) == "string" and item.id:match("^[%w_]+$") and not entries[item.id], "模块名称无效或重复")
        entries[item.id] = {
            id = item.id, title = item.title or item.id, description = item.description or "",
            enabled = item.enabled ~= false, options = copy(item.options or {}),
            defaults = copy(item.defaults or { enabled = item.enabled ~= false, options = item.options or {} }),
            running = item.running == true, module = item.module, error = item.error, registered = item.registered == true,
        }
        registry[index] = entries[item.id]
        order[#order + 1] = item.id
    end
    menu = hs.menubar.new():setTitle("脚本")
    -- 可见图标始终只处理点击，避免 macOS 缓存已挂载的下拉菜单。
    contextMenu = hs.menubar.new(false)
    contextMenu:setMenu(function()
        local items = { { title = "打开设置…", fn = M.show }, { title = "-" } }
        for _, entry in ipairs(M.status()) do
            local id = entry.id
            items[#items + 1] = { title = entry.title, checked = entry.running, fn = function()
                local ok, err = M.apply(id, not entry.running, entry.options)
                if not ok then hs.alert.show("设置失败：" .. tostring(err)) end
                publish(ok and "已更新" or tostring(err), ok, ok and id or nil)
            end }
        end
        return items
    end)
    menu:setClickCallback(function()
        if hs.eventtap.checkMouseButtons().right then
            contextMenu:popupMenu(hs.mouse.absolutePosition())
        else
            M.show()
        end
    end)
    return M
end
return M
