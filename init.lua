------------------------------------------------------------
-- Hammerspoon init.lua
------------------------------------------------------------

-- 快捷键统一在这里配置，由各模块负责绑定或监听。
-- hotkey.mods 使用 ctrl / alt（Option）/ cmd / shift。
-- hotkey.bind = false 跳过绑定或监听；true 或省略时启用。
require("modules.window_resize").start({
    hotkey = {
        mods = { "ctrl", "cmd", "shift" },
        key = "5",
    },
})

-- 明确使用 msmtp 的 qq 账户：2468080401@qq.com 发给 469753862@qq.com。
require("modules.lockscreen_camera").start({
    account = "qq",
    from = "2468080401@qq.com",
    fromName = "MacBook Pro 21 M1 Pro",
    to = { "469753862@qq.com" },
    ignoredSSIDs = { "galaxy", "galaxy-5G" }, -- 连接到这些 Wi-Fi 时不拍摄、不发信
    lockedInterval = 5,        -- 锁屏唤醒后拍摄间隔（秒）
    afterUnlockCount = 10,     -- 后续阶段拍摄总数，不包含归入第一封邮件的解锁补拍（张）
    afterUnlockInterval = 30,  -- 后续阶段首张等待时间（从解锁起算）及拍摄间隔（秒）
})

-- 监听应用的关闭窗口快捷键，不拦截原始按键。
require("modules.close_last_window_hide").start({
    hotkey = {
        mods = { "cmd" },
        key = "W",
    },
})

-- 测试快捷键默认不绑定，定时提醒照常启动；测试时将 hotkey.bind 改为 true。
require("modules.blink_reminder").start({
    intervalMinutes = 30,        -- 每轮提醒间隔（分钟）
    snoozeMinutes = { 5, 10 }, -- 可延后的分钟数；{} 禁用延后
    hoverSeconds = 10,           -- 每次连续悬停时间（秒）
    hoverCount = 3,              -- 关闭共需悬停并点击的次数，含「已休息」这一次
    hotkey = {
        mods = { "ctrl", "alt", "cmd" },
        key = "B",
        bind = false,
    },
})

-- USB 插拔时查询 ADB：有可用 Android 设备则启动 Moorage，否则请求正常退出。
require("modules.android_moorage").start({
    adb = "/opt/homebrew/bin/adb",
    -- appBundleID = "com.skylerschoos.moorage",
    appBundleID = "com.sudomaker.MacMTP",
    disconnectDelay = 1, -- 确认无可用设备后等待 1 秒，再请求正常退出一次。
})

-- Cron：分 时 日 月 星期；url / cron 均支持字符串或数组，使用系统默认浏览器。
require("modules.scheduled_webpages").start({
    schedules = {
        { url = "https://wcj.plus/productsStatistics", cron = { "0 14 * * *", "0 17 * * *" } }, -- 每天 14:00、17:00
        -- { url = { "https://example.com", "https://example.org" }, cron = { "0 9 * * 1-5", "0 18 * * 1-5" } },
    },
})


-- 规则省略时使用第一项；"choose" 从全局配置中选择，也可传自定义数组。
require("modules.browser-dispatcher").start({
    browsers = { "chrome", "edge", "safari", "firefox" },
    profiles = { "Default", "Profile 1" }, -- Firefox 按 Profile 名称匹配
    logLevel = "debug",
    rules = {
        {
            urls = "www.jlc.com/newOrder", -- 字符串或数组；高级匹配另用 patterns（Lua 模式）
            profile = "choose",
        },
    },
})


hs.alert.show("Hammerspoon 配置已加载")
