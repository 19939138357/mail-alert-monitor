# 安卓「监控机 1」

安卓手机在同一 Wi-Fi 下查看 Mac 的监控状态、最近扫描、推送记录，或发起一次连接。手机退到后台后，电脑继续监控。支持 Android 8 及以上，Mac 需 macOS 14 及以上。这个版本的手机配对服务运行在 Mac 上。

## 第一次使用

1. 从本项目的 GitHub Releases 下载 Mac 压缩包和 `MailAlertMonitor-Android.apk`。解压后将两个 Mac 应用放在同一文件夹。首次在 Mac 监控台选中邮箱窗口、完成校准并启动扫描。
2. 点击 Mac 监控台侧栏的「手机配对」，选本机 Wi-Fi 地址，点「显示 6 位配对码」。配对工具使用 Python 3.8 或更新版本。Apple 命令行工具、Homebrew 或 python.org 的标准 macOS 安装均可提供 Python。
3. 在同一 Wi-Fi 下打开安卓「监控机 1」。输入六位数字，选择自己的电脑并点「配对并连接」。自动发现失败时点「手动填地址」，照抄 Mac 配对窗口的地址。配对码五分钟有效，仅能成功使用一次。
4. 在首页看状态和每封邮件的原主题。手机只在首页前台刷新。需要从手机启动监控时，在 Mac 允许相应的辅助功能权限。停止手机访问，可回 Mac 点击「停止手机连接」。撤销已配对手机，在 Mac 选「撤销所有手机配对」。

**查看邮箱画面（选用）。** 在 Mac 监控台选中并确认 Safari 中的具体邮箱页面，再到配对窗口勾选「与手机共享已确认的 Foxmail 邮箱画面」，开启手机连接。校验包含网址中的查询参数和页面片段，仅以指纹比对。更换远程会话需要在监控台重新确认，然后停止并重新开启手机连接。需要 Mac 的录屏与辅助功能权限、可见的邮箱列表与正文预览。安卓打开「Foxmail 画面」，支持双指缩放。手动点击仅接受已推送且确认为已读的邮件。对不上窗口、网页或推送记录时会显示原因。首次选择邮箱和授权须在 Mac 完成。

下载的 APK 沿用 1.1 的应用标识与签名，可以覆盖升级，并继续使用原电脑配对。首次切换到另一台电脑或独立部署的公开 Mac 配对工具时，在手机上重新配对。

## 从源码构建

- **Android**：在 macOS 或 Linux 准备 Python 3.8+、JDK 17、Android SDK Platform 35 和 Build Tools 35.0.0。设置 `JAVA_HOME` 与 `ANDROID_SDK_ROOT` 后，从仓库根目录执行 `python3 handset/android/build.py`。构建脚本会编译、签名并校验 `dist/MailAlertMonitor-Android.apk`。可通过 `ANDROID_BUILD_TOOLS` 指定等效工具目录。
- 首次个人构建会在本地 `handset/android/.signing/` 生成自己的签名。请安全备份，后续构建需沿用此签名以覆盖自己的安装。官方 APK 与自行签名的 APK 不能互相覆盖。发布者可显式指定私有签名目录 `MAIL_HANDSET_SIGNING_DIR`，其中应已有 `handset-release.p12`（别名 `handset-release`）及相应的 `password` 文件。签名材料不随仓库分发。
- **Mac 配对工具**：在 macOS 14+ 的 Mac 安装带 macOS 14+ SDK 的 Xcode 或命令行工具，从仓库根目录运行 `bash handset/mac/build-pair.sh`。生成 `dist/手机配对.app`，支持 Apple 芯片和 Intel。与 `dist/抽查邮件监控开源版.app` 放在一起使用。

## 验证

- 在 `handset/mac` 运行 `python3 -m unittest discover -p 'test_*.py'`，验证限速、一次性配对码和接口的访问控制。
- 构建并放好两份 Mac App 后，在仓库根目录运行 `python3 handset/mac/tests/packaged_status.py dist`。此检查通过本机回环和一次性测试身份读取状态，在测试结束时停止服务。
- 安卓与 Mac 跨语言配对测试使用 JDK 17 和测试依赖 `org.json:json:20240303`。在仓库根目录执行 `python3 handset/android/tests/test_code_interop.py MAC_LAN_IP --jdk-bin "$JAVA_HOME/bin" --json-jar /path/to/json.jar`。使用本机可绑定的局域网 IPv4 地址。测试覆盖错误码、前导零、单次使用、服务端证明、证书与目标地址绑定。
