# Android 本地告警响铃助手

收到微信、QQ 邮箱或钉钉的独立系统通知后，检查 `【夜间告警】` 标记及事件身份，持续响铃和振动，直到用户选择“已处理”。普通聊天和验证码不触发持续闹铃。应用没有 Internet 权限，通知内容只在本机处理。

公开版包名为 `org.example.mailalertalarm`，与原本机版本分离。最低 Android 8.0/API 26，目标 API 35。本仓库只含自有 Java、XML 和构建/测试源码，不携带签名密钥、APK、SDK/JDK 或真实通知数据。

## 在 Windows 构建

先自行安装支持 Java 8 编译目标的 JDK，以及 Android SDK 的 `platforms;android-35` 和 `build-tools;35.0.0`。设置 `ANDROID_SDK_ROOT`（或 `ANDROID_HOME`）与 `JAVA_HOME`，或显式传参：

```powershell
powershell.exe -NoProfile -File .\Build.ps1 -SdkRoot C:\Android\Sdk -JdkHome C:\Java\jdk
```

原生构建脚本用于 Windows，使用本机的 `aapt.exe`、`zipalign.exe`、D8 和 apksigner，不下载任何依赖。SDK 路径宜使用 ASCII 字符，规避旧版 Windows aapt 的路径编码问题。也可用 `-OutputPath` 指定 APK 输出位置。

构建会运行两项纯 Java 测试与静态检查，生成原创双音 WAV，编译资源与 Java/Dex，使用本机新生成的**开发测试签名**签名并校验。默认 APK 在 `dist/notification-alarm.apk`，过程和检查结果在 `build/`。首次生成的 `signing/local-debug.keystore` 使用 Android 标准调试口令，仅用于本地测试；正式分发应使用你自己的发布签名流程，不要提交密钥。

## 手机首次使用

自行构建并安装 APK 后，选择要监听的通知应用，按系统页面授权通知访问与 Android 13+ 通知权限；如需锁屏全屏提醒，还需在受支持系统中批准对应权限。检查手机的音量、勿扰、后台及电池设置，然后先用本机铃声测试，再开启守护并发送一条真实的新告警。

消息标题或正文示例：

```text
【夜间告警】示例设备异常 [事件:demo-event-0001]
```

不同告警使用不同事件身份，同一告警的更新保持原身份。关闭守护或更换通知来源会停止当前铃声。手机重启或被强制停止后需要打开助手重新开启。

## 验证边界

本次发布整理在 macOS 进行，未安装 Java/Android SDK，也未在手机运行更名后的公开包；Android 编译、签名和真机收件/响铃验收仍需使用者完成。纯逻辑测试与静态检查不代表后台、锁屏、通话、省电或整夜可靠性。通知被隐藏、只有汇总通知、网络收件延迟或系统终止后台时均可能漏报。
