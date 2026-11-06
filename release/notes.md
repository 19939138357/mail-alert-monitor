下载与你设备对应的文件。

| 文件 | 怎么用 |
| --- | --- |
| **MailAlertMonitor-macOS.zip** | macOS 14+，支持 Apple 芯片和 Intel。解压后将两个 App 放在同一文件夹，打开「抽查邮件监控开源版」。 |
| **MailAlertMonitor-Windows.zip** | Windows 10/11。完整解压后双击 MailAlertMonitor.exe，在「监控设置」选择邮箱。 |
| **MailAlertMonitor-Android.apk** | 安卓 8+。安装「监控机 1」，与 Mac 同一 Wi-Fi，在手机输入 Mac 显示的六位配对码。已有 1.1 版可覆盖升级。 |

Mac 首页直接展示原邮件主题、运行状态和待核对数量。安卓六位码控制端目前连接 Mac，Mac 上的手机配对工具需要 Python 3.8+。Windows 支持三种模式：Foxmail 未读邮件正文、抽查确认码、屏幕关键词。未读模式支持在窗口中框选列表和正文，并按原主题推送核对完成的邮件。请将远程正文滚动条框进阅读区，无法核实末尾的邮件会保留在「待核对邮件」。

Mac 采用本地签名，未做 Apple 公证。公开版首次使用请配置自己的邮箱窗口、权限和通知渠道。SHA256SUMS.txt 用于核对下载完成的三个文件。
