# .hammerspoon

Hammerspoon 脚本集合，功能及快捷键由 `init.lua` 统一配置。

| 脚本 | 功能 | 绑定快捷键 / 监听事件 |
| --- | --- | --- |
| [install.sh](install.sh) | 将仓库目录软链接到 `~/.hammerspoon`；已有其他配置时提示并退出，已正确链接时提示已就绪。 | 手动执行：`./install.sh`。 |
| [init.lua](init.lua) | 配置并启动各模块。 | 加载或重新加载配置。 |
| [window_resize.lua](modules/window_resize.lua) | 将当前窗口调整为预置或自定义尺寸，并居中显示。 | 绑定：`Ctrl + Cmd + Shift + 5`。 |
| [lockscreen_camera.lua](modules/lockscreen_camera.lua) | 锁屏唤醒拍照、解锁时补拍及解锁后定时拍摄，分阶段发送邮件，成功后清理照片及日期目录；连接指定 Wi-Fi 时跳过。 | 监听：锁屏、解锁、显示器休眠与唤醒、系统休眠与关机、用户会话离开及 Wi-Fi 变化；无快捷键。 |
| [close_last_window_hide.lua](modules/close_last_window_hide.lua) | 关闭应用最后一个窗口后自动隐藏应用，不拦截原有关闭操作。 | 监听：`Cmd + W`。 |
| [blink_reminder.lua](modules/blink_reminder.lua) | 每 20 分钟提醒休息，支持延后及悬停确认关闭。 | 测试快捷键：`Ctrl + Option + Cmd + B`，默认不绑定。 |
| [android_moorage.lua](modules/android_moorage.lua) | 有可用 Android 设备时启动 Moorage，无可用设备时退出；重新启动前等待退出完成。 | 监听：USB 插拔及 Moorage 退出；每次插拔查询一次 ADB，无快捷键。 |
| [scheduled_webpages.lua](modules/scheduled_webpages.lua) | 使用 Cron 表达式定时打开网页，支持链接与 Cron 数组，使用系统默认浏览器。 | 定时触发；无快捷键。 |
| [browser-dispatcher.lua](modules/browser-dispatcher.lua) | 按网址或来源应用分发链接，支持 Chrome、Edge、Safari、Firefox，以及浏览器和 Profile 选择。 | 接管系统 HTTP/HTTPS 链接；无快捷键。 |
