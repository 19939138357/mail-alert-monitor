# Windows 邮件监控

此目录包含 Windows PowerShell 5.1 OCR 监控、通知传输、WinForms 控制台和测试源码。它与当前 macOS 主线独立：Windows 的自动开信规则主要面向两类抽查邮件，不代表已经具有 macOS 主线的逐封完整正文功能。

公开副本中的门户、发件人和窗口地址均为合成示例。`portal.example.com:9978`、`report@example.com`、`192.0.2.x` 不会连接到原使用环境。

## 下载运行

在仓库 Releases 下载 `MailAlertMonitor-Windows.zip`，完整解压到可写目录，双击 `MailAlertMonitor.exe`。「监控设置」可以修改目标窗口、关键词和扫描间隔，「通知设置」配置手机接收渠道。首次运行自动复制示例配置，详细操作见包内 `使用说明.txt`。

从源码构建便携包，在 Windows 安装 Python 3、.NET Framework 4.8 后运行 `python legacy/windows/package.py`。脚本使用微软系统 C# 编译器和 SHA256 锁定的 NuGet 依赖，产物写入仓库 `dist/MailAlertMonitor-Windows.zip`。构建机需要访问 NuGet，最终用户下载 ZIP 后无需编译。系统 OCR、邮箱收件和推送配置仍需在实际 Windows 上测试。

## 运行脚本

环境：Windows 10/11、Windows PowerShell 5.1、.NET Framework 4.8，以及安装了相应识别语言的系统 OCR。此目录保留原相对结构，入口脚本在当前目录。

1. 复制 `monitor_config.example.json` 为 `monitor_config.json`。示例由公开版重新生成，不包含原账号、电话号码或 API 密钥。
2. 根据实际窗口调整 `windowTitleContains`、`processNameContains` 与裁剪区域。先运行只读窗口检查：

   ```powershell
   powershell.exe -NoProfile -File .\Monitor-WindowKeywords.ps1 -ListWindows
   ```

3. 运行 `Configure-PhoneNotification.ps1`，在本机填写自己的通知通道配置。凭据由 Windows 当前用户加密保存于自动生成的 `04_资料/私密配置/`；该目录不应进入 Git。
4. 用 `Test-VerificationPhone.ps1` 发送一条明确的测试通知，核对手机后再开始实际监控：

   ```powershell
   powershell.exe -NoProfile -File .\Monitor-WindowKeywords.ps1
   ```

示例默认关闭自动开信和验证码提取，不对启动时已有内容直接告警。如需启用抽查开信，请将 `mailConfirmationSender` 设置为自己的完整发件邮箱地址，并校准列表和正文范围。在自己的邮箱和手机完成验证。PaddleOCR Python 后端是可选项：自行安装其运行依赖、将 `ocrProvider` 配成 `paddle`，并遵守所用包及模型的许可证；本仓库不分发模型或缓存。脚本还保留外部 OCR 接口功能，启用会把截图发送到你填写的服务，默认地址和密钥为空。

## 开发者单独构建 WinForms 控制台

源码位于 `03_交付物/告警抽查桌面版/`，使用系统 .NET Framework C# 编译器。构建前自行从官方 NuGet 包恢复 **AntdUI 2.4.11/net48**，将其 `AntdUI.dll` 放到该目录，然后运行 `build.ps1`。该 DLL 不包含在仓库内；原锁定包和 DLL 的 SHA256 记录见 `dependencies.lock.json`，依赖许可证见 `AntdUI-LICENSE.txt`。

官方来源：<https://www.nuget.org/packages/AntdUI/2.4.11>。AntdUI 采用 Apache-2.0，分发它时保留其版权和许可证。控制台蓝色铃铛图标为本项目原创，所需 ICO/PNG/SVG 已作为资源提供。

可选 Edge 登录功能需要自行安装 Node.js，并在 `03_交付物/告警抽查桌面版/browser/` 运行 `npm install` 恢复原快照依赖 `playwright-core`。启动程序通过 PATH 的 `node.exe` 运行，也可用 `MAILALERT_NODE` 指定完整路径。Edge 使用系统安装，本仓库不分发浏览器、Node 运行时或 `node_modules`。

登录适配器保留严格的 HTTPS 来源和表单检查。部署到自己的门户前，需要同步修改 `EdgeSystemLogin.cs` 中 `TargetUrl` 和 `browser/edge-login.js` 中 `TARGET_URL`/`TARGET_ORIGIN`，重新构建并验证表单。不要通过放宽来源检查来适配未知页面。动态验证、证书及系统验证由使用者本人处理。

## 网页扩展

公开扩展位于仓库根目录的 `browser-extension/`。运行 `Configure-BrowserAlert.ps1` 可启动本机接收端并显示配对操作。接收端只监听 `127.0.0.1:17368`，配对码在本机生成，不含于公开源码。普通 DOM 邮箱与远程桌面画布使用不同实现；扩展不能读取远程画布内的 Foxmail。

## 检查及限制

- Windows 回归脚本位于 `tests/`。运行前检查对应测试的依赖；这些测试包含模拟发送，不能代替真实手机收件验证。
- 纯 JavaScript 扩展测试可用 Node.js 运行 `tests/Test-BrowserAlertCore.js`、`tests/Test-BrowserContentLifecycle.js`、`tests/Test-BrowserExtensionLifecycle.js`。
- 公开副本在 macOS 整理；本次使用 .NET Framework 4.8 参考程序集交叉编译 WinForms 程序并验证包内文件；真实 Windows OCR、Edge 登录、系统加密和手机收件仍需现场验证。
- OCR 可能漏字或无法唯一确定邮件身份；外部通知服务受理不等于手机送达，未知发送结果保留待核对。保持运行数据和凭据不被提交。

Windows 原生便携包自测：在仓库根目录运行 `powershell -NoProfile -ExecutionPolicy Bypass -File legacy/windows/tests/Test-PortableRelease.ps1`。此检查只启动自己解压的控制台，检查配置持久化并渲染首页。
