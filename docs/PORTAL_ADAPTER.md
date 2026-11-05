# 对接自己的远程门户

公开源码使用 `https://portal.example.com:9978`、文档保留地址 `192.0.2.11` 及示例门户名称。它们不会连接原使用环境；请仅对接自己有权访问的系统。

适配时一致更新：

- `macos/App.swift`：SystemPortal URL 与目标标题。
- `macos/SafariDevice.swift`、`macos/Recovery.swift`：精确源站、路由、设备窗口标题及可见设备入口。
- `macos/portal-login.js`、`macos/portal-device.js`：源站、设备唯一身份及网页结构。
- `macos/SystemLogin.swift`：登录脚本的同源入口。
- 对应 `.test.cjs` 和 Swift 自测的合成期望值。
- 旧 Windows 门户入口还涉及 `EdgeSystemLogin.cs` 和 `browser/edge-login.js`。

不要为兼容门户而移除源站、设备行身份、可见性、遮挡、前台和输入空闲核对。只修改地址不能保证网页结构兼容。动态验证、系统身份验证和证书提示仍由本人处理；不复制临时远程会话 URL 到源码。

普通窗口监控可通过选择窗口和校准区域使用；一键连接与自动恢复仅适用于已完成适配的门户。修改源码后先构建公开版、运行合成隔离测试，再用自己的环境核对未读、完整正文、通知及恢复。构建使用临时本地签名，重建可能使 macOS 重新要求权限。
