# 邮件监控与手机提醒 · Mail Alert Monitor

从可见的远程邮箱画面发现未读邮件，读取完整正文，再通过手机通知通道提醒。适用于只能在远程桌面查看邮箱、暂时没有邮件服务器接口的场景。

当前 macOS 主线来自 1.3.15，仓库同时保留 Windows 旧实现、浏览器扩展和 Android 响铃助手。此仓库是经过隐私清理的源码版本，门户、邮箱和设备标识均为示例，需要适配自己的环境。

## 能做什么

- macOS 原生界面：选择邮箱窗口、校准列表和正文区域、查看队列及运行状态。
- 连续核对未读标记，点击前保存整批任务；逐页读取正文后再发送通知。
- 通知标题优先显示邮件时间和原主题；相同主题按核对过的身份区分。
- 持久保存发送意图、正文和去重记录；结果不明确时等待本人核对，不盲目重发。
- PushPlus 微信通知、本机故障提示、受控的 Safari 门户适配及断线重试。
- Android 通知监听与持续响铃；Windows 旧版还保留 QQ 邮箱、钉钉等通道。

## 源码目录

| 目录 | 内容 |
| --- | --- |
| `macos/` | SwiftUI、Vision OCR、ScreenCaptureKit、Keychain、Safari 适配与隔离测试 |
| `legacy/windows/` | PowerShell 监控、WinForms 控制台源码与旧版测试 |
| `browser-extension/` | 基于 Manifest V3 的主动网页监控扩展 |
| `android-alarm/` | 使用 Android 系统 API 的通知响铃助手 |
| `docs/` | 门户适配、隐私与依赖说明 |

## macOS 快速开始

需要 Apple Silicon Mac、macOS 14 或更高版本及 Xcode Command Line Tools。构建只输出本仓库的 `dist/` 和 `.build/`。

```bash
bash macos/build.sh
open 'dist/抽查邮件监控开源版.app'
```

构建会生成完全合成的邮件列表样本，并运行原生自测。不会复制本机邮件截图或已有配置。录屏、辅助功能、Safari 控制等权限由使用者按自己需要授予。

1. 可先运行合成样本，核对识别效果。
2. 选择自己的远程邮箱窗口，校准蓝色列表区域与绿色正文区域。
3. 在通知设置中配置自己的 PushPlus Token；实际内容会发送给你所配置的服务。
4. Foxmail 按“是否已读”排序，展开未读、收起已读；保持远程邮箱可访问。
5. 对接门户的一键入口前，先按 [门户适配说明](docs/PORTAL_ADAPTER.md) 修改示例配置并运行测试。

JavaScript 表单和设备入口检查使用 Node.js：

```bash
node macos/portal-login.test.cjs
node macos/portal-device.test.cjs
```

Windows、扩展和 Android 的构建说明见各自目录。它们作为旧平台源码保留，不代表已在本轮 Mac 环境重新通过 Windows 或真机端到端验收。

## 运行边界与已知问题

这是画面 OCR 工具，不是邮箱服务器订阅。布局变化、睡眠、锁屏、未读标记缺失、远程离线及识别失败都可能影响发现和读取；不承诺每封邮件实时送达。

1.3.15 的自动重连仍有已知限制：有过关闭远程标签后停在空白页的情况，也有在第 5 次尝试、约 5 分半后才恢复的情况。重试不等于连接已恢复。双帧核对与持续扫描用于确认实际恢复，仍需针对自己的门户验证。

推送服务受理与手机实际收到分别核对。服务未提供可靠幂等确认时，请求超时不能证明未送达；待核对任务不自动重发。OCR 也可能无法区分发件人、主题和时间完全相同的两封邮件。需要严格完整覆盖时，应接入稳定邮件 ID 和邮箱服务端接口。

## 数据与开源范围

macOS 开源版的本机数据位于 `~/Library/Application Support/MailAlertMonitorOpenSource/`；钥匙串使用独立服务标识。队列可能包含邮件正文，勿提交或公开这个目录。详见 [隐私说明](docs/PRIVACY.md)。

本仓库不包含真实账号、Token、邮件、原始截图、运行记录、浏览器登录资料、签名私钥、SDK、模型缓存、历史构建或应用安装包。测试使用示例地址和合成内容。

## 许可证

自有源码以 [MIT License](LICENSE) 发布。第三方工具、平台和依赖按各自许可证使用，见 [第三方说明](THIRD_PARTY_NOTICES.md)。
