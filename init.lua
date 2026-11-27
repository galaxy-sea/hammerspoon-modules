-- 启动脚本。
local scripts = require("modules.script_manager").load()
-- 可选 GUI：注释这一行，不影响脚本启动和运行。
require("modules.script_manager").start({ modules = scripts })



-- 也可完全自行配置，直接调用任意脚本，不需要 config.lua 或 GUI：
-- require("modules.blink_reminder").start({ intervalMinutes = 20 })


hs.alert.show("Hammerspoon 配置已加载")
