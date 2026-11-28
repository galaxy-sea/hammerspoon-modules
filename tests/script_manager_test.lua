-- Run with Lua, or the LuaSkin runner on a Mac with Hammerspoon installed.
local saved, failSave, menuBuilder, legacySaved, failRename
local clearedLegacy = 0
local storedJSON, jsonValues, nextJSON = nil, {}, 0
local menuCreations = 0
local mouseButtons = {}
local menuClick, poppedItems
local officialIcon = true
local running, starts, stops, loads = {}, {}, {}, {}
local function duplicate(value)
    if type(value) ~= "table" then return value end
    local result = {}; for key, item in pairs(value) do result[key] = duplicate(item) end
    return result
end
hs = {
    menuIcon = function(visible) officialIcon = visible end,
    configdir = "/tmp/script-manager-test",
    image = { imageFromPath = function(path)
        assert(path:match("modules/%.%./icon%.svg$"))
        return { setSize = function(self, size) assert(size.w == 18 and size.h == 18); return self end }
    end },
    eventtap = { checkMouseButtons = function() return mouseButtons end },
    mouse = { absolutePosition = function() return { x = 10, y = 10 } end },
    logger = { new = function() return { w = function() end } end },
    json = {
        encode = function(value)
            nextJSON = nextJSON + 1
            local token = "json:" .. nextJSON
            jsonValues[token] = duplicate(value)
            return token
        end,
        decode = function() return duplicate(saved) end,
    },
    settings = {
        get = function() return duplicate(legacySaved) end,
        set = function() error("GUI settings must not be written to application preferences") end,
        clear = function() legacySaved = nil; clearedLegacy = clearedLegacy + 1 end,
    },
    alert = { show = function() end },
    printf = function() end,
    menubar = { new = function()
        menuCreations = menuCreations + 1
        return {
            setTitle = function(self) return self end,
            setIcon = function(self, icon, template) assert(icon and template); return self end,
            setMenu = function(_, fn) menuBuilder = fn end,
            setClickCallback = function(_, fn) menuClick = fn end,
            popupMenu = function() poppedItems = menuBuilder() end,
            delete = function() end,
        }
    end },
}
-- Virtual files exercise the same write/close/rename transaction without touching user settings.
local realOpen, realRename, realRemove = io.open, os.rename, os.remove
local configPath = hs.configdir .. "/script_settings.json"
io.open = function(path, mode)
    if path == configPath and mode == "r" then
        if saved == nil then return nil, "No such file", 2 end
        return { read = function() return "stored" end, close = function() return true end }
    elseif path == configPath .. ".tmp" and mode == "w" then
        if failSave then return nil, "disk unavailable", 13 end
        return { write = function(self, data) storedJSON = data; return self end, close = function() return true end }
    end
    return realOpen(path, mode)
end
os.rename = function(source, target)
    if source == configPath .. ".tmp" and target == configPath then
        if failRename then return nil, "rename denied" end
        saved = duplicate(assert(jsonValues[storedJSON])); return true
    end
    return realRename(source, target)
end
os.remove = function(path)
    if path == configPath .. ".tmp" then storedJSON = nil; return true end
    return realRemove(path)
end
for _, id in ipairs({ "test_one", "test_two", "test_broken", "test_new", "test_extra", "test_manual" }) do
    package.preload["modules." .. id] = function()
        loads[id] = (loads[id] or 0) + 1
        return {
            start = function(options)
                starts[id] = (starts[id] or 0) + 1
                running[id] = options.value
                if options.fail or id == "test_broken" then error("invalid configuration") end
                options.value = "mutated by module"
            end,
            stop = function()
                stops[id] = (stops[id] or 0) + 1
                running[id] = nil
            end,
        }
    end
end
local definitions = {
    { id = "test_one", enabled = true, options = { value = "original" } },
    { id = "test_two", enabled = false, options = { value = "second" } },
}
local actualConfig = dofile("config.lua")
local sourceFile = assert(io.open("init.lua", "r"))
local initSource = sourceFile:read("*a"); sourceFile:close()
-- Exercise the actual independent startup path with GUI import omitted.
local headlessInit = initSource:gsub('require%("modules%.script_manager"%).start%({ modules = scripts, showHammerspoonMenuIcon = false }%)', '')
assert(headlessInit ~= initSource)
local function launch(defs)
    package.loaded.config = duplicate(defs)
    return assert(load(headlessInit .. "\nreturn scripts", "@init.lua"))()
end
local function stopScripts()
    for _, id in ipairs({ "test_one", "test_two", "test_broken", "test_new", "test_extra", "test_manual" }) do
        local module = package.loaded["modules." .. id]
        if module then module.stop() end
    end
end
local registry = launch(definitions)
assert(officialIcon, "headless startup must keep the official menu available")
assert(menuCreations == 0 and #require("modules.script_manager").status() == 0, "load must not create GUI or attach its state")
assert(running.test_one == "original" and loads.test_two == nil, "disabled module must not load")
assert(definitions[1].options.value == "original", "module must receive a copy")
local manager = require("modules.script_manager")
local beforeStarts, beforeStops = starts.test_one, stops.test_one
manager.start({ modules = registry })
assert(not officialIcon, "ready GUI must replace the official menu icon")
manager.start({ modules = registry, showHammerspoonMenuIcon = true })
assert(officialIcon, "showHammerspoonMenuIcon=true must keep the official icon alongside the GUI")
manager.start({ modules = registry, showHammerspoonMenuIcon = false })
assert(not officialIcon, "showHammerspoonMenuIcon=false must hide the official icon once GUI is ready")
manager.stop()
assert(officialIcon, "stopping GUI must restore the official menu icon")
assert(starts.test_one == beforeStarts and stops.test_one == beforeStops and running.test_one == "original",
    "GUI attach/detach must not change running scripts")
manager.start({ modules = registry })
assert(manager.apply("test_one", true, { value = "updated" }))
assert(saved.test_one.options.value == "updated" and running.test_one == "updated")
local state = manager.status(); state[1].options.value = "external mutation"
assert(manager.status()[1].options.value == "updated", "status must be a copy")
local ok, err = manager.apply("test_one", true, { value = "bad", fail = true })
assert(not ok and err:find("invalid configuration", 1, true))
assert(running.test_one == "updated" and saved.test_one.options.value == "updated", "failed startup must rollback and not persist")
failSave = true
ok = manager.apply("test_one", false, {})
assert(not ok and running.test_one == "updated", "persistence failure must restore old running state")
failSave = false
local before = stops.test_one
assert(not manager.apply("test_one", true, { callback = function() end }))
assert(stops.test_one == before, "invalid data must fail before stopping module")
assert(not manager.apply("missing", true, {}))
assert(manager.apply("test_two", true, { value = "enabled" }))
assert(running.test_two == "enabled")
manager.stop()
assert(running.test_one == "updated" and running.test_two == "enabled", "GUI stop must leave all scripts running")
stopScripts()
registry = launch(definitions)
assert(running.test_one == "updated" and running.test_two == "enabled", "saved state must survive restart without GUI")
manager.start({ modules = registry })
local originalShow, opened = manager.show, 0
manager.show = function() opened = opened + 1 end
mouseButtons = { left = true }
menuClick()
assert(opened == 1 and poppedItems == nil, "left click must open settings directly")
mouseButtons = { right = true }
menuClick()
local items = poppedItems; assert(items[3].checked and opened == 1, "right click must retain the script menu")
mouseButtons = { left = true }
poppedItems = nil
menuClick()
assert(opened == 2 and poppedItems == nil, "left click after right click must open settings without reopening the menu")
mouseButtons = {}
manager.show = originalShow
items[3].fn(); assert(running.test_one == nil and saved.test_one.enabled == false)
assert(running.test_two == "enabled", "changing one script must leave other scripts running")
manager.stop(); stopScripts()
registry = launch({ { id = "test_broken", options = {} }, { id = "test_one", options = {value='ok'} } })
manager.start({ modules = registry })
state = manager.status(); assert(state[1].error and not state[1].running, "startup errors must be visible")
assert(state[2].error == nil, "failed module must not prevent other modules from initializing")
manager.stop(); stopScripts()
-- GUI registration starts only the new script, preserves metadata, and survives headless reload.
registry = launch(definitions)
manager.start({ modules = registry })
local otherStarts = starts.test_two
assert(not manager.register({ id = "test_two" }), "duplicate registration must be rejected")
assert(not manager.register({ id = "../outside" }), "invalid module names must be rejected")
package.loaded["modules.loaded_elsewhere"] = { start = function() error("must not start") end }
assert(not manager.register({ id = "loaded_elsewhere" }), "already-loaded unmanaged scripts must not be started again")
assert(not manager.register({ id = "test_new", options = { fail = true } }))
assert(running.test_new == nil and package.loaded["modules.test_new"] == nil and not saved.test_new,
    "failed registration must clean up without saving and permit retry")
assert(manager.register({ id = "test_new", title = "New script", options = { value = "new" } }))
assert(running.test_new == "new" and starts.test_two == otherStarts, "registration must not restart other scripts")
assert(saved.test_new.registered and saved.test_new.title == "New script")
assert(manager.apply("test_new", true, { value = "edited" }))
assert(saved.test_new.registered and saved.test_new.defaults.options.value == "new", "editing must retain registration and defaults")
failSave = true
assert(not manager.register({ id = "test_extra", options = { value = "extra" } }))
assert(running.test_extra == nil and not saved.test_extra and package.loaded["modules.test_extra"] == nil)
failSave = false
manager.stop(); assert(running.test_new == "edited")
manager.start({ modules = registry })
local found = false
for _, item in ipairs(manager.status()) do if item.id == "test_new" then found = item.running and item.options.value == "edited" end end
assert(found, "GUI reattach must retain dynamically registered scripts")
manager.stop(); stopScripts()
registry = launch(definitions)
assert(running.test_new == "edited", "GUI registrations must restart without importing GUI")
local beforeNewStarts = starts.test_new
stopScripts()
local manual = duplicate(definitions)
manual[#manual + 1] = { id = "test_new", title = "Manual", options = { value = "manual" } }
registry = launch(manual)
assert(starts.test_new == beforeNewStarts + 1, "manual and saved registration of the same ID must start only once")
stopScripts()
package.loaded.config = duplicate(definitions)
local manualInit = headlessInit:gsub('local scripts = require%("modules%.script_manager"%).load%(%)',
    'local scripts = require("modules.script_manager").load()\nscripts.register("test_manual", { value = "manual" })')
assert(manualInit ~= headlessInit)
assert(load(manualInit .. "\nreturn scripts", "@init.lua"))()
assert(running.test_manual == "manual", "init.lua must support register(name, options)")
stopScripts()
-- One-line startup loads defaults once, even when GUI is reopened.
manager.start()
local oneLineStarts = starts.test_two
manager.start()
assert(starts.test_two == oneLineStarts, "repeated start must not restart scripts")
manager.stop(); manager.start()
assert(starts.test_two == oneLineStarts, "reopening optional GUI must reuse its loaded scripts")
manager.stop(); stopScripts()
-- Deleted scripts are excluded even when require still has a cached module.
manager.stop(); stopScripts()
local goneModule = { start = function() error("deleted script must not start") end, stop = function() end }
package.loaded["modules.test_gone"] = goneModule
saved.test_gone = { registered = true, enabled = true, options = {} }
registry = launch({ { id = "test_gone", enabled = true }, { id = "test_gone_disabled", enabled = false } })
for _, item in ipairs(registry) do
    assert(item.id ~= "test_gone" and item.id ~= "test_gone_disabled", "missing files must be skipped for both enabled and disabled scripts")
end
manager.start({ modules = { { id = "test_gone", enabled = true, running = true, module = goneModule } } })
assert(#manager.status() == 0, "stale registrations must not appear in UI or menus")
assert(#menuBuilder() == 2, "missing scripts must not generate menu items")
assert(not manager.apply("test_gone", true, {}), "cached deleted modules must not be restarted")
assert(not manager.register({ id = "test_absent", enabled = false }), "GUI must reject nonexistent files")
assert(saved.test_gone.registered, "skip deleted files without destroying saved preferences")
manager.stop()
-- Missing/broken config.lua must not prevent recovering settings or opening GUI.
stopScripts()
local originalSearchpath = package.searchpath
package.searchpath = function(name, path)
    if name == "config" then return nil, "missing config" end
    return originalSearchpath(name, path)
end
saved.test_one = { enabled = true, options = { value = "recovered without config" } }
registry = manager.load()
assert(running.test_one == "recovered without config", "saved overrides must recover even without original config")
manager.start({ modules = registry })
assert(#manager.status() > 0, "GUI must remain usable after config deletion")
manager.stop(); stopScripts()
local previousSaved = saved
saved = nil
registry = manager.load()
assert(#registry == 0, "missing config with no saved settings must produce a safe empty list")
manager.start({ modules = registry }); assert(#menuBuilder() == 2)
manager.stop()
saved = previousSaved
package.searchpath = originalSearchpath
local originalConfig = package.loaded.config
package.loaded.config = nil
package.preload.config = function() error("broken config fixture") end
registry = manager.load()
assert(running.test_one == "recovered without config", "broken config must also permit recovery")
stopScripts()
package.preload.config = nil
package.loaded.config = originalConfig
-- Configuration lives in the installation directory; legacy settings migrate only after a successful write.
manager.stop(); stopScripts()
local previousFile = saved
saved = nil
legacySaved = { test_one = { enabled = true, options = { value = "legacy migrated" } } }
local previousClears = clearedLegacy
failSave = true
assert(not pcall(manager.load, {}))
assert(legacySaved and saved == nil and clearedLegacy == previousClears, "failed migration must preserve old settings")
failSave = false
registry = manager.load({ { id = "test_one", options = { value = "default" } } })
assert(saved.test_one.options.value == "legacy migrated" and legacySaved == nil)
assert(clearedLegacy == previousClears + 1 and running.test_one == "legacy migrated")
manager.start({ modules = registry })
failRename = true
assert(not manager.apply("test_one", true, { value = "cannot commit" }))
assert(saved.test_one.options.value == "legacy migrated" and running.test_one == "legacy migrated", "failed atomic replacement must preserve file and running config")
failRename = false
manager.stop(); stopScripts()
saved = previousFile
-- Config migration retains the existing module set and enabled states.
local config = actualConfig
assert(#config == 9)
local byID = {}; for _, item in ipairs(config) do byID[item.id] = item end
assert(byID.dev_tools.enabled == false and byID.blink_reminder.options.intervalMinutes == 30)
assert(byID.input_assistant.options.appInputSources["com.apple.keylayout.ABC"][1] == "com.apple.Spotlight")
-- Window resize now releases chooser and hotkey handles on stop/restart.
local deletedKeys, deletedChoosers = 0, 0
hs.chooser = { new = function()
    return setmetatable({}, { __index = function(_, key)
        if key == "delete" then return function() deletedChoosers = deletedChoosers + 1 end end
        return function(self) return self end
    end })
end }
hs.hotkey = { bind = function() return { delete = function() deletedKeys = deletedKeys + 1 end } end }
local resize = require("modules.window_resize")
resize.start({ hotkey = { mods = { "cmd" }, key = "5" } })
resize.start({ hotkey = { mods = { "cmd" }, key = "6" } })
assert(deletedKeys == 1 and deletedChoosers == 1)
resize.stop(); assert(deletedKeys == 2 and deletedChoosers == 2)
resize.stop(); assert(deletedKeys == 2, "stop must be idempotent")
assert(resize.parameters[1].key == "hotkey" and resize.parameters[1].default.key == "5")
assert(resize.parameters[1].type == nil and resize.parameters[1].min == nil, "simple parameter declaration must not require type or range")
resize.start(); resize.stop()
assert(deletedKeys == 3 and deletedChoosers == 3, "standalone start must also use declared shortcut defaults")
manager.start({ modules = { { id = "window_resize", enabled = false, options = {} } } })
state = manager.status()
assert(state[1].parameters[1].label == "调整窗口快捷键", "GUI must receive declared parameters even when the script is disabled")
assert(deletedKeys == 3, "reading parameter metadata must not start the script")
manager.stop()
-- Reading the camera form must not start a camera, create files, or send mail.
hs.configdir = "/tmp/script-manager-test"
local camera = require("modules.lockscreen_camera")
assert(#camera.parameters == 4)
local cameraKeys = {}
for _, group in ipairs(camera.parameters) do
    for _, parameter in ipairs(group.fields) do
        assert(parameter.type == nil and parameter.min == nil and parameter.unit == nil)
        cameraKeys[parameter.key] = parameter.default
    end
end
assert(cameraKeys.lockedInterval == 5 and cameraKeys.warmup == 0.5)
assert(type(cameraKeys.to) == "table" and type(cameraKeys.ignoredSSIDs) == "table")
assert(cameraKeys.device == nil and cameraKeys.stateRoot == nil and cameraKeys.deviceName == "" and cameraKeys.msmtp == nil and cameraKeys.imagesnap == nil)
manager.start({ modules = { { id = "lockscreen_camera", enabled = false, options = {} } } })
state = manager.status()
assert(state[1].parameters[1].label == "邮件通知")
assert(not camera.status().running and not camera.status().cameraRunning and not camera.status().mailRunning)
manager.stop()
-- Generate the real MIME without starting the camera or sending a message.
assert(cameraKeys.from == nil and cameraKeys.fromName == nil, "sender fields must not be exposed in GUI")
local function upvalue(fn, wanted)
    for index = 1, 100 do
        local name, value = debug.getupvalue(fn, index)
        if not name then break end
        if name == wanted then return value, index end
    end
    error("missing upvalue " .. wanted)
end
local pump = upvalue(camera.start, "pumpMail")
local renderMessage = upvalue(pump, "message")
local _, configIndex = upvalue(renderMessage, "cfg")
debug.setupvalue(renderMessage, configIndex, {
    deviceName = "Demo device", to = { "recipient@example.test" }, maxMailBytes = 1024 * 1024,
})
local encodedHeaders = {}
hs.base64 = { encode = function(value) encodedHeaders[#encodedHeaders + 1] = value; return "ZGVtbw==" end }
local report = { id = "demo-report", nextPart = 1, kind = "locked", photos = {}, parts = { {}, {} },
    startedText = "start", endedText = "end", reason = "demo", dir = "/tmp/demo" }
local mime = renderMessage(report)
assert(mime:find("To: recipient@example.test", 1, true))
assert(not mime:find("From:", 1, true), "msmtp must supply sender headers from its account")
assert(encodedHeaders[1] == "Demo device - 锁屏异常唤醒", "subject must identify the device without a sender setting")
report.nextPart = 2
assert(renderMessage(report):find("In-Reply-To: <demo-report.1@lockscreen-camera.local>", 1, true), "mail threading must survive simplification")
-- Auto-hide passively listens to Cmd+W and never binds or swallows the shortcut.
local keyCallback, delayed, hidden, windows = nil, {}, 0, {}
local target = { pid = function() return 123 end, bundleID = function() return "test.app" end,
    allWindows = function() return windows end, hide = function() hidden = hidden + 1 end }
hs.keycodes = { map = { w = 13 } }
hs.hotkey.bind = function() error("auto-hide must not bind a hotkey") end
hs.application = { frontmostApplication = function() return target end, applicationForPID = function() return target end }
hs.eventtap = { event = { types = { keyDown = 1 } }, new = function(_, callback)
    keyCallback = callback
    return { start = function() end, stop = function() end }
end }
hs.timer = { doAfter = function(_, callback) delayed[#delayed + 1] = callback end }
local autoHide = require("modules.close_last_window_hide")
assert(next(autoHide.parameters) == nil)
autoHide.start()
local function press(flags, code)
    return keyCallback({ getFlags = function() return flags end, getKeyCode = function() return code or 13 end })
end
assert(press({ cmd = true }) == false); delayed[#delayed](); assert(hidden == 1)
windows = { {} }; press({ cmd = true }); delayed[#delayed](); assert(hidden == 1)
local pending = #delayed
assert(press({ cmd = true, shift = true }) == false and #delayed == pending)
assert(press({ cmd = true, alt = true }) == false and #delayed == pending)
assert(press({ cmd = true }, 99) == false and #delayed == pending)
windows = {}; press({ cmd = true }); local oldCallback = delayed[#delayed]
autoHide.stop(); autoHide.start(); oldCallback(); assert(hidden == 1, "stopped/restarted module must ignore old delayed callbacks")
autoHide.stop()
-- Reminder metadata reuses runtime defaults; merely loading it never schedules anything.
local reminder = require("modules.blink_reminder")
assert(reminder.parameters[1].fields[1].default == 20)
assert(reminder.parameters[3].default.bind == false)
local scheduled, bound, timerStops = nil, 0, 0
hs.timer = { doAfter = function(seconds)
    scheduled = seconds
    return { stop = function() timerStops = timerStops + 1 end }
end }
hs.webview = { usercontent = { new = function() return { setCallback = function() end } end } }
hs.hotkey.bind = function() bound = bound + 1; return { delete = function() end } end
reminder.start()
assert(scheduled == 20 * 60 and bound == 0 and _G.blinkReminderApp.hoverCount == 3)
reminder.stop()
reminder.start({ intervalMinutes = 30, snoozeMinutes = { 5, 10 }, hoverSeconds = 8, hoverCount = 2,
    hotkey = { mods = { "cmd" }, key = "R", bind = true } })
assert(scheduled == 30 * 60 and bound == 1 and _G.blinkReminderApp.hoverSeconds == 8)
assert(#_G.blinkReminderApp.snoozeMinutes == 2)
reminder.stop(); assert(timerStops == 2)
-- Native app selection reads only the selected bundle and preserves cancel/error results.
local oldDialog, oldApplication = hs.dialog, hs.application
hs.dialog = { chooseFileOrFolder = function(_, directory, files, folders, multiple, extensions, aliases)
    assert(directory == "/Applications" and files and not folders and not multiple and extensions[1] == "app" and aliases)
    return { "/Applications/OpenMTP.app" }
end }
hs.application = { infoForBundlePath = function(path)
    assert(path == "/Applications/OpenMTP.app")
    return { CFBundleIdentifier = "test.openmtp", CFBundleName = "OpenMTP" }
end }
local picked = manager.chooseApplication();assert(picked.id == "test.openmtp" and picked.name == "OpenMTP")
hs.application.infoForBundlePath = function() return nil end
local _, pickerError = manager.chooseApplication();assert(pickerError)
hs.dialog.chooseFileOrFolder = function() return nil end
local cancelled, cancelError = manager.chooseApplication();assert(cancelled == nil and cancelError == nil)
hs.dialog, hs.application = oldDialog, oldApplication
local mtp = require("modules.usb_MTP_finder")
assert(mtp.parameters[1].fields[1].options == "application")
assert(mtp.parameters[1].fields[2].default == 1 and mtp.parameters[2].fields[1].default == 10)
local webpages = require("modules.scheduled_webpages")
assert(webpages.parameters[1].key == "schedules" and #webpages.parameters[1].fields == 3)
assert(webpages.parameters[1].fields[3].default[1] == "0 9 * * 1-5")
assert(webpages.status().running == false, "loading webpage parameter definitions must not schedule or open URLs")
-- Browser parameter metadata must not launch browsers; GUI-only app matching remains valid at runtime.
local originalPathLookup = hs.application.pathForBundleID
hs.application.pathForBundleID = function() return nil end
local browserDispatcher = require("modules.browser_dispatcher")
assert(browserDispatcher.parameters[1].label == "浏览器与用户配置")
assert(browserDispatcher.parameters[2].key == "rules" and #browserDispatcher.parameters[2].fields == 2)
assert(browserDispatcher.installation.command:find("Lua", 1, true))
local oldSpoon, oldLoadSpoon, oldURLEvent = spoon, hs.loadSpoon, hs.urlevent
local selectedLevel
local dispatcher = { logger = { setLogLevel = function(level) selectedLevel = level end },
    start = function() hs.urlevent.httpCallback = function() end end }
spoon = { URLDispatcher = dispatcher }
hs.loadSpoon = function(name) assert(name == "URLDispatcher") end
hs.urlevent = { httpCallback = function() end }
browserDispatcher.start({ browsers = { "safari" }, profiles = { "Default" }, rules = { { apps = { "微信" } } } })
assert(selectedLevel == "info" and dispatcher.default_handler == "com.apple.Safari")
assert(dispatcher.url_patterns[1][1][1] == "^https?://" and ("微信"):match(dispatcher.url_patterns[1][4][1]) ~= nil)
browserDispatcher.stop()
spoon, hs.loadSpoon, hs.urlevent = oldSpoon, oldLoadSpoon, oldURLEvent
hs.application.pathForBundleID = originalPathLookup
-- Input-source discovery lists enabled sources without switching the active input method.
local oldKeycodes = hs.keycodes
hs.keycodes = {
    layouts = function(ids) return ids and { "com.apple.keylayout.ABC" } or { "ABC" } end,
    methods = function(ids) return ids and { "org.fcitx.inputmethod.Fcitx5.zhHans", "com.apple.keylayout.ABC" } or { "Fcitx5", "ABC duplicate" } end,
    currentSourceID = function() error("source discovery must not switch or query the active input source") end,
}
local sources = manager.inputSources()
assert(#sources == 2 and sources[1].label == "ABC" and sources[2].value == "org.fcitx.inputmethod.Fcitx5.zhHans")
local inputAssistant = require("modules.input_assistant")
assert(inputAssistant.parameters[1].fields[1].options == "inputSources")
assert(inputAssistant.parameters[2].fields[1].item.options == "application")
assert(inputAssistant.parameters[3].control == "map" and inputAssistant.parameters[4].valueField.options[1].value == "chromeAddress")
hs.keycodes = oldKeycodes
-- Default loading discovers files once, excludes the manager, and never starts new scripts.
stopScripts()
local oldFS, oldConfig = hs.fs, package.loaded.config
local scans = 0
hs.fs = { dir = function(directory)
    assert(directory:match("modules/$"))
    scans = scans + 1
    local names, index = { ".", "..", "script_manager.lua", "test_discovered.lua", "script_manager.html" }, 0
    return function() index = index + 1; return names[index] end
end }
package.preload["modules.test_discovered"] = function() error("discovery must not load disabled scripts") end
package.loaded.config = {}
local discovered = manager.load()
assert(scans == 1)
local item
for _, candidate in ipairs(discovered) do if candidate.id == "test_discovered" then item = candidate end end
assert(item and not item.enabled and not item.running)
manager.load({})
assert(scans == 1, "explicit module lists must remain independent of directory discovery")
hs.fs, package.loaded.config = oldFS, oldConfig
package.preload["modules.test_discovered"] = nil
print("PASS: independent startup, optional GUI attach/detach, persistence, restart, rollback, manual/GUI registration, duplicate prevention, menu toggles, config migration, hotkey cleanup")
