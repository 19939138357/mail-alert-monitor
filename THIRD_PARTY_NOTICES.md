# 第三方与资源说明

根 MIT 许可证适用于本项目自有源码，不为外部组件重新授予许可证。

- macOS 使用 Apple 系统框架（SwiftUI、AppKit、Vision、ScreenCaptureKit、Security 等），构建工具由使用者自行安装并遵循 Apple 的相应条款；本仓库不分发这些框架。
- Windows 桌面应用使用 AntdUI 2.4.11（Apache-2.0）。Windows 下载包附带经过校验的 DLL 和 Apache-2.0 许可证。源码仓库保留校验值和独立许可证。
- Windows Edge 自动登录依赖 Node.js、playwright-core，均由使用者按各自许可证自行获取；未附带其二进制或 node_modules。
- 可选 PaddleOCR 后端需要单独安装 Python、OCR 库及模型并遵循各自许可；本仓库不附带模型权重。
- Android 助手使用 Android 平台 API，SDK/JDK 和签名密钥由使用者自行准备；仓库只包含自有 Java/XML/构建源码及本地生成音频的方法。
- Foxmail、Safari、Edge、微信、QQ 邮箱、PushPlus、钉钉和 Apache Guacamole 为外部软件或服务。本仓库包含接口或界面适配，不包含它们的完整应用或品牌素材，也不表示其官方支持。
- macOS 图标为本项目生成资源；Windows 图标为本项目绘制资源。邮件列表测试图片由 `macos/GenerateSample.swift` 本地合成，不含真实邮件。

安卓控制端以及配对工具使用系统网络接口，局域网发现采用 DNS-SD，通信通过 HTTPS。六位码配对协议与独立 Android 响铃助手的依赖说明见各自源码目录。

MiMo 本地识别使用 XiaomiMiMo/MiMo-VL-7B-RL-2508 的社区量化权重和 llama.cpp，本地安装工具按 local-mimo/model.json 固定修订与摘要获取。MiMo 模型及 llama.cpp 使用各自的 MIT 条款，小米 MiMo-VL 源码仓库另有其许可证。权重和运行程序在用户首次安装时下载，来源、量化者及原始链接见 local-mimo/README.md。
