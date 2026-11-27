# .hammerspoon

一组让 Mac 用起来更顺手的小脚本：自动切换输入法、提醒休息、整理窗口，以及按需打开浏览器和设备管理软件。

一个轻量级的脚本集合，让你的 Mac 少一些后台负担，发挥本应拥有的性能。小工具就应该短小精悍。

## 功能列表
功能和快捷键可以在 [init.lua](init.lua) 中调整，修改后重新加载 Hammerspoon 配置即可。

| 脚本 | 功能 | 使用方式 |
| --- | --- | --- |
| [install.sh](install.sh) | 将这套脚本设置为 Hammerspoon 配置；已有其他配置时会提示。 | 执行 `./install.sh`。 |
| [init.lua](init.lua) | 集中设置需要启用的功能和快捷键。 | 加载配置后自动启动。 |
| [dev_tools.lua](modules/dev_tools.lua) | 开发辅助工具，可拖动浮窗显示应用和输入法信息，支持复制 ID、清空日志和重载配置。 | 自动更新，无需快捷键。 |
| [window_resize.lua](modules/window_resize.lua) | 将当前窗口调整到指定大小，并居中显示。 | `Ctrl + Cmd + Shift + 5`。 |
| [lockscreen_camera.lua](modules/lockscreen_camera.lua) | 锁屏唤醒、解锁及解锁后拍照并发送邮件，发送成功后清理照片；可设置在指定 Wi-Fi 下跳过。 | 自动运行。 |
| [close_last_window_hide.lua](modules/close_last_window_hide.lua) | 关闭应用最后一个窗口后，自动隐藏应用。 | 按 `Cmd + W` 关闭窗口时生效。 |
| [blink_reminder.lua](modules/blink_reminder.lua) | 定时提醒眼睛休息，可选择延后；按钮随机出现，悬停并确认后关闭。提醒间隔、延后时间和确认次数均可调整。 | 自动提醒；测试快捷键 `Ctrl + Option + Cmd + B` 默认关闭。 |
| [usb_MTP_finder.lua](modules/usb_MTP_finder.lua) | 连接可识别的 MTP 文件传输设备时，自动打开你指定的软件；断开后自动退出。 | 插拔 USB 设备时生效。 |
| [scheduled_webpages.lua](modules/scheduled_webpages.lua) | 按指定时间自动打开一个或多个网页。 | 到时间后使用默认浏览器打开。 |
| [browser_dispatcher.lua](modules/browser_dispatcher.lua) | 根据网址或打开链接的软件，选择浏览器及用户配置，也可以每次弹窗选择。支持 Chrome、Edge、Safari 和 Firefox。 | 点击外部链接时生效。 |
| [input_assistant.lua](modules/input_assistant.lua) | 根据应用和输入区域自动切换输入法，可按软件设置中文状态下使用英文标点。 | 自动切换，无需快捷键。 |

## 可替代的软件

如果只需要下表中的功能，可以使用对应脚本代替独立软件；替代范围以列出的功能为准。

| 功能 | 对应脚本 | 同类软件 | 脚本提供的功能 |
| --- | --- | --- | --- |
| 自动切换输入法 | [input_assistant.lua](modules/input_assistant.lua) | 自动切换输入法专业版（Better365）、TypeRelay Pro、[Input Source Pro](https://github.com/runjuu/InputSourcePro)、KeyboardHolder | 按应用和指定输入区域切换输入法，按软件使用英文标点。 |
| 浏览器智能分流 | [browser_dispatcher.lua](modules/browser_dispatcher.lua) | OpenIn、[Choosy](https://choosy.app/)、[Finicky](https://github.com/johnste/finicky)、[Velja](https://sindresorhus.com/velja) | 根据网址或来源应用选择浏览器及用户配置，也可弹窗选择。 |
| 窗口管理 | [window_resize.lua](modules/window_resize.lua) | Wins、Magnet、[Moom](https://manytricks.com/moom/)、[Rectangle](https://rectangleapp.com/)、Loop | 通过快捷键调整窗口大小并居中。 |
| 应用窗口自动隐藏 | [close_last_window_hide.lua](modules/close_last_window_hide.lua) | Quitter 类工具、Swift Quit（自动退出）及综合效率工具 | 关闭最后一个窗口后自动隐藏应用；隐藏后应用继续运行。 |
| 护眼休息提醒 | [blink_reminder.lua](modules/blink_reminder.lua) | Eye Monitor、一休、[LookAway](https://lookaway.com/)、[Stretchly](https://github.com/hovancik/stretchly)、Time Out | 定时提醒休息，支持延后提醒和自定义间隔。 |
| 定时打开网页 | [scheduled_webpages.lua](modules/scheduled_webpages.lua) | [Tab Scheduler](https://chromewebstore.google.com/detail/tab-scheduler-with-auto-o/dhpkakcoddfplipjgbhklfgomilbecnj)、[Tab Snooze](https://chromewebstore.google.com/detail/tab-snooze/kgnigbfnfjgpfaiaafcbgdkpalapiinb)（Chrome 插件） | 按计划自动打开网页，例如每个工作日上午打开工作页面。 |

> 不知道怎么改？直接上 AI 一梭子，或者在 Issues 中提出你的需求。
