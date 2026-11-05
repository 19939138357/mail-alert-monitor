# 第三方与资源说明

根 MIT 许可证适用于本项目自有源码，不为外部组件重新授予许可证。

- macOS 使用 Apple 系统框架（SwiftUI、AppKit、Vision、ScreenCaptureKit、Security 等），构建工具由使用者自行安装并遵循 Apple 的相应条款；本仓库不分发这些框架。
- Windows 桌面旧实现使用 AntdUI 2.4.11（Apache-2.0）。保留其独立许可证文件；依赖 DLL、NuGet 包及构建缓存不入库。
- Windows Edge 自动登录依赖 Node.js、playwright-core，均由使用者按各自许可证自行获取；未附带其二进制或 node_modules。
- 可选 PaddleOCR 后端需要单独安装 Python、OCR 库及模型并遵循各自许可；本仓库不附带模型权重。
- Android 助手使用 Android 平台 API，SDK/JDK 和签名密钥由使用者自行准备；仓库只包含自有 Java/XML/构建源码及本地生成音频的方法。
- Foxmail、Safari、Edge、微信、QQ 邮箱、PushPlus、钉钉和 Apache Guacamole 为外部软件或服务。本仓库包含接口或界面适配，不包含它们的完整应用或品牌素材，也不表示其官方支持。
- macOS 图标为本项目生成资源；Windows 图标为本项目绘制资源。邮件列表测试图片由 `macos/GenerateSample.swift` 本地合成，不含真实邮件。
