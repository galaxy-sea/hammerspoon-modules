-- 默认配置；本机保存的设置优先于此文件，不加载 GUI 也会生效。
-- 仍可直接编辑这里，再在面板中恢复默认并保存。
return {
    {
        id = "window_resize",
        title = "窗口调整",
        description = "调整窗口尺寸并居中。",
        enabled = true,
        options = {
            hotkey = {
                mods = { "ctrl", "cmd", "shift" },
                key = "5",
            },
        },
    },
    {
        id = "lockscreen_camera",
        title = "解锁拍照",
        description = "锁屏唤醒、解锁拍照及邮件提醒。",
        enabled = true,
        options = {
            account = "qq",
            from = "2468080401@qq.com",
            fromName = "MacBook Pro 21 M1 Pro",
            to = { "469753862@qq.com" },
            ignoredSSIDs = { "galaxy", "galaxy-5G" }, -- 连接到这些 Wi-Fi 时不拍摄、不发信
            lockedInterval = 5,        -- 锁屏唤醒后拍摄间隔（秒）
            afterUnlockCount = 10,     -- 后续阶段拍摄总数，不包含归入第一封邮件的解锁补拍（张）
            afterUnlockInterval = 30,  -- 后续阶段首张等待时间（从解锁起算）及拍摄间隔（秒）
        },
    },
    {
        id = "close_last_window_hide",
        title = "自动隐藏应用",
        description = "关闭最后一个窗口后隐藏应用。",
        enabled = true,
        options = {
            hotkey = {
                mods = { "cmd" },
                key = "W",
            },
        },
    },
    {
        id = "blink_reminder",
        title = "休息提醒",
        description = "定时提醒休息，支持延后和悬停确认。",
        enabled = true,
        options = {
            intervalMinutes = 30,        -- 每轮提醒间隔（分钟）
            snoozeMinutes = { 5, 10 }, -- 可延后的分钟数；{} 禁用延后
            hoverSeconds = 10,           -- 每次连续悬停时间（秒）
            hoverCount = 3,              -- 关闭共需悬停并点击的次数，含「已休息」这一次
            hotkey = {
                mods = { "ctrl", "alt", "cmd" },
                key = "B",
                bind = false,
            },
        },
    },
    {
        id = "usb_MTP_finder",
        title = "MTP 软件启停",
        description = "插入设备时打开文件传输软件，拔出后退出。",
        enabled = true,
        options = {
            appBundleID = "com.sudomaker.MacMTP",
            disconnectDelay = 1, -- 确认无可用设备后等待 1 秒，再请求正常退出一次。
        },
    },
    {
        id = "scheduled_webpages",
        title = "定时打开网页",
        description = "按计划打开工作页面或其他网址。",
        enabled = true,
        options = {
            schedules = {
                { url = "https://wcj.plus/productsStatistics", cron = { "0 14 * * *", "0 17 * * *" } }, -- 每天 14:00、17:00
                -- { url = { "https://example.com", "https://example.org" }, cron = { "0 9 * * 1-5", "0 18 * * 1-5" } },
            },
        },
    },
    {
        id = "browser_dispatcher",
        title = "浏览器分流",
        description = "按网址或来源应用选择浏览器与用户配置。",
        enabled = true,
        options = {
            browsers = { "chrome", "edge", "safari", "firefox" },
            profiles = { "Default", "Profile 1" }, -- Firefox 按 Profile 名称匹配
            logLevel = "debug",
            rules = {
                {
                    urls = "www.jlc.com/newOrder", -- 字符串或数组；高级匹配另用 patterns（Lua 模式）
                    profile = "choose",
                },
            },
        },
    },
    {
        id = "input_assistant",
        title = "输入助手",
        description = "按应用和输入区域切换输入法，并转换英文标点。",
        enabled = true,
        options = {
            defaultSource = "org.fcitx.inputmethod.Fcitx5.zhHans",
            englishPunctuation = { -- 列出的应用转换英文标点，支持 * 前缀匹配
                "com.microsoft.VSCode",
                "com.jetbrains.*",
                "com.apple.Terminal",
            },
            appInputSources = { -- 按照应用切换到对应的输入法，Bundle ID 支持 * 前缀匹配
                ["com.apple.keylayout.ABC"] = {
                    "com.apple.Spotlight",
                    "com.apple.Terminal",
                    -- "com.microsoft.VSCode",
                    "com.microsoft.VSCodeInsiders",
                    "com.jetbrains.*", -- * 为 Bundle ID 前缀匹配
                },
            },
            focusInputSources = { -- 按照应用窗口切换输入法，不需要就直接注释了，无法自由配置
                ["com.apple.keylayout.ABC"] = {
                    "chromeAddress", -- Chrome 地址栏
                    "vscodeConsolePanel", -- VS Code 控制台面板
                },
                ["org.fcitx.inputmethod.Fcitx5.zhHans"] = {
                    "vscodeChat", -- VS Code ChatGPT/Codex 聊天输入框
                },
            },
        },
    },
    {
        id = "dev_tools",
        title = "开发辅助工具",
        description = "浮窗查看应用和输入法信息，复制 ID、清空日志或重载配置。",
        enabled = false,
        options = { width = 500, margin = 4 },
    },
}
