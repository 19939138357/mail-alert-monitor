import AppKit
import CoreImage.CIFilterBuiltins
import Darwin
import SwiftUI

struct LocalRoute: Identifiable, Hashable {
    let interface: String
    let address: String
    let overlay: Bool
    var id: String { address }
    var label: String { (overlay ? "私人网络" : "局域网") + " · " + address + " (" + interface + ")" }

    static func available() -> [LocalRoute] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        var routes = [LocalRoute]()
        var seen = Set<String>()
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = item.pointee
            guard (entry.ifa_flags & UInt32(IFF_UP)) != 0, let addr = entry.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let octets = ip.split(separator: ".").compactMap { Int($0) }
            guard octets.count == 4, seen.insert(ip).inserted else { continue }
            let vpn = octets[0] == 100 && (64...127).contains(octets[1])
            guard vpn || octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
                    || (octets[0] == 192 && octets[1] == 168) else { continue }
            routes.append(LocalRoute(interface: String(cString: entry.ifa_name), address: ip, overlay: vpn))
        }
        return routes.sorted { lhs, rhs in
            if lhs.overlay != rhs.overlay { return lhs.overlay }
            let l = lhs.interface.hasPrefix("en"), r = rhs.interface.hasPrefix("en")
            return l == r ? lhs.interface < rhs.interface : l
        }
    }
}

@MainActor final class Pairing: ObservableObject {
    @Published var routes = [LocalRoute]()
    @Published var address = ""
    @Published var shareMailbox = false
    @Published var message = ""
    @Published var link = ""
    @Published var image: NSImage?
    @Published var busy = false
    @Published var code = ""
    @Published var expiresAt: Date?
    @Published var discoveryFailed = false
    private let discovery = PairingDiscovery()
    private var expiry: Timer?
    private var child: Process?
    private var control: FileHandle?
    private var renewRequest: UUID?
    private var offerID = UUID()
    private var generation = UUID()
    var active: Bool { child != nil }

    init() { refresh() }

    func refresh() {
        routes = LocalRoute.available()
        if !routes.contains(where: { $0.address == address }) { address = routes.first?.address ?? "" }
    }

    func start(rotate: Bool = false) {
        guard child == nil, !address.isEmpty, let res = Bundle.main.resourceURL else { return }
        let apps = Bundle.main.bundleURL.deletingLastPathComponent()
        guard Bundle(url:apps.appendingPathComponent("抽查邮件监控开源版.app"))?.bundleIdentifier == "org.example.mailalertmonitor" else {
            message = "请将开源版监控和手机配对移到同一个文件夹，再开启连接。"
            return
        }
        let storage = FileManager.default.urls(for:.applicationSupportDirectory, in:.userDomainMask)[0]
            .appendingPathComponent("MailAlertMonitorOpenSource/PhonePairing")
        var candidates = ["/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
        if FileManager.default.isExecutableFile(atPath:"/Library/Developer/CommandLineTools/usr/bin/python3")
            || FileManager.default.isExecutableFile(atPath:"/Applications/Xcode.app/Contents/Developer/usr/bin/python3") {
            candidates.append("/usr/bin/python3")
        }
        guard let python = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            message = "手机连接需要 Python 3。请安装 macOS 版 Python 3 或 Apple 命令行工具，然后重试。"
            return
        }
        var approved = ""
        if shareMailbox {
            let settings = storage.deletingLastPathComponent().appendingPathComponent("settings.json")
            guard let selected = try? MailboxApproval.read(from: settings),
                  let digest = selected.shareableDigest else {
                message = "请先在开源版监控中选择并确认 Safari 邮箱页面，再开启画面共享。"
                return
            }
            approved = digest
        }
        let token = UUID()
        generation = token
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: python)
        task.arguments = [res.appendingPathComponent("bridge.py").path, "--bind", address, "--apps", apps.path, "--private-dir", storage.path,
                          "--helper", res.appendingPathComponent("MailControlHost").path] + (rotate ? ["--rotate"] : [])
        var env = ProcessInfo.processInfo.environment
        env["MAIL_MONITOR_FRAME_APPROVAL"] = approved
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        task.environment = env
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        let commands = Pipe()
        task.standardInput = commands
        let writeEnd = commands.fileHandleForWriting
        guard fcntl(writeEnd.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            message = "无法建立本机配对控制通道，请重新开启。"
            return
        }
        child = task
        busy = true
        message = "正在启动加密连接…"
        do { try task.run() } catch {
            child = nil; busy = false; message = "无法启动电脑端。" + error.localizedDescription; return
        }
        control = writeEnd
        // The bridge streams newline-delimited notices, including after pairing has completed.
        let selectedAddress = address
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = pipe.fileHandleForReading
            var buffer = Data()
            var invalidOutput = false
            consume: while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    guard line.count <= 8192 else { invalidOutput = true; break consume }
                    let notice = BridgeNotice.decode(line, address: selectedAddress)
                    DispatchQueue.main.async {
                        guard self.generation == token else { return }
                        self.receive(notice)
                    }
                }
                if buffer.count > 8192 { invalidOutput = true; break }
            }
            if (invalidOutput || !buffer.isEmpty) && task.isRunning { task.terminate() }
            task.waitUntilExit()
            DispatchQueue.main.async {
                guard self.generation == token else { return }
                self.child = nil
                self.closeControl()
                self.busy = false
                self.clearOffer()
                if !self.link.isEmpty || self.message == "正在启动加密连接…" {
                    self.message = "手机连接已停止，可以重新开启"
                }
                self.link = ""; self.image = nil
            }
        }
    }

    func renew() {
        guard let child, child.isRunning, !busy, let control else { return }
        clearOffer()
        let request = UUID()
        renewRequest = request
        busy = true
        message = "正在获取新的六位码…"
        do {
            try control.write(contentsOf: Data("renew\n".utf8))
        } catch {
            renewRequest = nil
            busy = false
            message = "未能获取新码，请停止手机连接并重新开启。"
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard self.renewRequest == request else { return }
            self.renewRequest = nil
            self.busy = false
            self.message = "电脑端尚未返回新码，请再试一次。"
        }
    }

    private func closeControl() {
        renewRequest = nil
        try? control?.close()
        control = nil
    }

    private func clearOffer() {
        offerID = UUID()
        expiry?.invalidate()
        expiry = nil
        code = ""; expiresAt = nil
        discovery.stop()
        discoveryFailed = false
    }

    private func receive(_ notice: BridgeNotice) {
        switch notice {
        case .ready(let offer):
            busy = false
            renewRequest = nil
            clearOffer()
            link = offer.link
            image = Self.qr(offer.link)
            code = offer.code
            expiresAt = Date().addingTimeInterval(TimeInterval(offer.lifetime))
            message = ""
            let token = offerID
            expiry = Timer.scheduledTimer(withTimeInterval: TimeInterval(offer.lifetime), repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.offerID == token, !self.code.isEmpty else { return }
                    self.receive(.closed(.expired))
                }
            }
            if let route = routes.first(where: { $0.address == address }) {
                discovery.start(route: route, port: offer.port) { [weak self] in self?.discoveryFailed = true }
            } else {
                discoveryFailed = true
            }
        case .closed(let reason):
            guard renewRequest == nil else { return }
            clearOffer()
            message = reason.message
        case .failure(let error):
            busy = false
            closeControl()
            clearOffer()
            link = ""; image = nil; message = error
            if let child, child.isRunning { child.terminate() }
        }
    }

    func stop() {
        generation = UUID()
        if let task = child, task.isRunning {
            task.terminate()
            task.waitUntilExit()
        }
        closeControl()
        clearOffer()
        child = nil; busy = false; link = ""; image = nil; message = "手机连接已停止"
    }

    func copy() {
        guard !link.isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(link, forType: .string)
        let change = board.changeCount
        message = "配对链接已复制，90 秒后清除剪贴板。"
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            if board.changeCount == change { board.clearContents() }
        }
    }

    static func qr(_ value: String) -> NSImage? {
        let gen = CIFilter.qrCodeGenerator()
        gen.message = Data(value.utf8)
        gen.correctionLevel = "M"
        guard let output = gen.outputImage else { return nil }
        let scaled = output.transformed(by: .init(scaleX: 6, y: 6))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width,height: cg.height))
    }
}

struct WindowView: View {
    @ObservedObject var pair: Pairing
    @State private var revoke = false
    @State private var showQR = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 15) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.08, green: 0.32, blue: 0.34))
                    Image(systemName: "iphone.and.arrow.forward").font(.system(size: 26, weight: .medium)).foregroundStyle(.white)
                }.frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text("手机配对").font(.title.bold())
                    Text("监控机 1").foregroundStyle(.secondary)
                }
                Spacer()
                if !pair.link.isEmpty { Label("已开启", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            Divider()
            HStack {
                Picker("连接网络", selection: $pair.address) {
                    if pair.routes.isEmpty { Text("没有可用网络").tag("") }
                    ForEach(pair.routes) { Text($0.label).tag($0.address) }
                }.disabled(pair.active)
                Button("刷新") { pair.refresh() }.disabled(pair.active)
            }
            if !pair.active {
                Toggle("与手机共享已确认的 Foxmail 邮箱画面", isOn: $pair.shareMailbox)
                if pair.shareMailbox {
                    Text("共享范围仅限监控台已确认的邮箱页面。更换远程会话后，需要重新确认并开启手机连接。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if pair.active && !pair.busy && !pair.link.isEmpty {
                if let end = pair.expiresAt, !pair.code.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("在安卓手机输入这 6 位数字").font(.headline)
                        Text(pair.code)
                            .font(.system(size: 48, weight: .semibold, design: .rounded))
                            .monospacedDigit().tracking(6)
                            .accessibilityLabel("配对码 " + pair.code.map(String.init).joined(separator: " "))
                        HStack {
                            Text("有效至 " + end.formatted(date: .omitted, time: .shortened))
                            Spacer()
                            Button("换一个码") { pair.renew() }
                        }.font(.callout)
                    }.padding(16).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    Button("获取新配对码") { pair.renew() }.buttonStyle(.borderedProminent)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(pair.discoveryFailed ? "自动发现不可用，请在手机输入电脑地址" : "手机找不到电脑时，手动输入此地址")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(pair.address).font(.body.monospacedDigit()).textSelection(.enabled)
                }
                if let qr = pair.image {
                    DisclosureGroup("扫码或使用原配对链接", isExpanded: $showQR) {
                        HStack(alignment: .center, spacing: 14) {
                            Image(nsImage: qr).interpolation(.none).resizable().frame(width: 146, height: 146)
                                .padding(14).background(.white).clipShape(RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel("私人配对二维码")
                            VStack(alignment: .leading, spacing: 10) {
                                Text("用手机相机扫描，或在 App 中粘贴链接。")
                                Button("复制配对链接") { pair.copy() }
                                Text("持有此链接的人可在所选网络内访问监控。").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.top, 8)
                    }
                }
            } else if !pair.busy {
                Text("同一 Wi-Fi 选局域网地址。使用手机流量时，先让两端加入同一私人网络，再选 Mac 的 VPN 地址。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !pair.message.isEmpty { Text(pair.message).font(.callout).accessibilityLabel(pair.message) }
            Spacer(minLength: 0)
            Menu("安装与权限") {
                Button("下载安卓 App") {
                    if let url = URL(string:"https://github.com/19939138357/mail-alert-monitor/releases/latest/download/MailAlertMonitor-Android.apk") { NSWorkspace.shared.open(url) }
                }
                Button("辅助功能设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
                }
                Button("屏幕录制设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
                }
            }.menuStyle(.borderlessButton).fixedSize()
            HStack {
                if pair.active {
                    Button("停止手机连接") { pair.stop() }.disabled(pair.busy)
                } else {
                    Button("显示 6 位配对码") { pair.start() }.buttonStyle(.borderedProminent).disabled(pair.address.isEmpty)
                }
                Spacer()
                Button("撤销所有手机配对…") { revoke = true }.disabled(pair.address.isEmpty || pair.busy)
            }
        }.padding(26).frame(width: 535).fixedSize(horizontal: false, vertical: true)
            .alert("撤销所有手机的访问权？", isPresented: $revoke) {
                Button("取消", role: .cancel) { }
                Button("撤销并重新配对", role: .destructive) { pair.stop(); pair.start(rotate: true) }
            } message: { Text("所有已配对手机都需要重新输入六位码。") }
    }
}

@main struct PairingApp: App {
    @StateObject private var pair = Pairing()
    var body: some Scene {
        Window("监控机 1 · 手机配对", id: "pair") { WindowView(pair: pair) }
            .windowResizability(.contentSize)
    }
}
