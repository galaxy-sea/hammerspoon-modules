-- Run with Lua, or the LuaSkin runner on a Mac with Hammerspoon installed.
local saved, failSave, menuBuilder
local menuCreations = 0
local running, starts, stops, loads = {}, {}, {}, {}
local function duplicate(value)
    if type(value) ~= "table" then return value end
    local result = {}; for key, item in pairs(value) do result[key] = duplicate(item) end
    return result
end
hs = {
    logger = { new = function() return { w = function() end } end },
    settings = {
        get = function() return duplicate(saved) end,
        set = function(_, value)
            if failSave then error("disk unavailable") end
            saved = duplicate(value)
        end,
    },
    alert = { show = function() end },
    printf = function() end,
    menubar = { new = function()
        menuCreations = menuCreations + 1
        return {
            setTitle = function(self) return self end,
            setMenu = function(_, fn) menuBuilder = fn end,
            delete = function() end,
        }
    end },
}
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
local headlessInit = initSource:gsub('require%("modules%.script_manager"%).start%({ modules = scripts }%)', '')
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
assert(menuCreations == 0 and #require("modules.script_manager").status() == 0, "load must not create GUI or attach its state")
assert(running.test_one == "original" and loads.test_two == nil, "disabled module must not load")
assert(definitions[1].options.value == "original", "module must receive a copy")
local manager = require("modules.script_manager")
local beforeStarts, beforeStops = starts.test_one, stops.test_one
manager.start({ modules = registry })
manager.stop()
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
local items = menuBuilder(); assert(items[3].checked)
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
print("PASS: independent startup, optional GUI attach/detach, persistence, restart, rollback, manual/GUI registration, duplicate prevention, menu toggles, config migration, hotkey cleanup")
