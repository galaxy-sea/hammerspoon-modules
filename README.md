# .hammerspoon

一组让 Mac 用起来更顺手的小脚本：自动切换输入法、提醒休息、整理窗口，以及按需打开浏览器和设备管理软件。

功能和快捷键可以在 [init.lua](init.lua) 中调整，修改后重新加载 Hammerspoon 配置即可。

| 脚本 | 功能 | 使用方式 |
| --- | --- | --- |
| [install.sh](install.sh) | 将这套脚本设置为 Hammerspoon 配置；已有其他配置时会提示。 | 执行 `./install.sh`。 |
| [init.lua](init.lua) | 集中设置需要启用的功能和快捷键。 | 加载配置后自动启动。 |
| [window_resize.lua](modules/window_resize.lua) | 将当前窗口调整到指定大小，并居中显示。 | `Ctrl + Cmd + Shift + 5`。 |
| [lockscreen_camera.lua](modules/lockscreen_camera.lua) | 锁屏唤醒、解锁及解锁后拍照并发送邮件，发送成功后清理照片；可设置在指定 Wi-Fi 下跳过。 | 自动运行。 |
| [close_last_window_hide.lua](modules/close_last_window_hide.lua) | 关闭应用最后一个窗口后，自动隐藏应用。 | 按 `Cmd + W` 关闭窗口时生效。 |
| [blink_reminder.lua](modules/blink_reminder.lua) | 定时提醒眼睛休息，可选择延后；按钮随机出现，悬停并确认后关闭。提醒间隔、延后时间和确认次数均可调整。 | 自动提醒；测试快捷键 `Ctrl + Option + Cmd + B` 默认关闭。 |
| [usb_MTP_finder.lua](modules/usb_MTP_finder.lua) | 连接可识别的 MTP 文件传输设备时，自动打开你指定的软件；断开后自动退出。 | 插拔 USB 设备时生效。 |
| [scheduled_webpages.lua](modules/scheduled_webpages.lua) | 按指定时间自动打开一个或多个网页。 | 到时间后使用默认浏览器打开。 |
| [browser_dispatcher.lua](modules/browser_dispatcher.lua) | 根据网址或打开链接的软件，选择浏览器及用户配置，也可以每次弹窗选择。支持 Chrome、Edge、Safari 和 Firefox。 | 点击外部链接时生效。 |
| [input_method.lua](modules/input_method.lua) | 切换应用时自动选择输入法；Chrome 地址栏和 VS Code 集成终端使用英文，离开后恢复对应的默认输入法。 | 自动切换，无需快捷键。 |
