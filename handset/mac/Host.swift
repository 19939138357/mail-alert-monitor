import AppKit
import ApplicationServices
import CryptoKit
import Darwin

typealias Payload = [String: Any]

enum Host {
    static let safari = "com.apple.Safari"
    static let appID = "org.example.mailalertmonitor"
    static let files = FileManager.default
    static let appPath = "抽查邮件监控开源版.app"
    static func privateDir() throws -> URL {
        Storage.root.appendingPathComponent("PhonePairing", isDirectory: true)
    }
    static func selection() throws -> MailboxApproval? {
        try MailboxApproval.read(from: Storage.root.appendingPathComponent("settings.json"))
    }
    static func project() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["MAIL_MONITOR_APPS"] else {
            throw failure("请从手机配对应用启动。")
        }
        let root = URL(fileURLWithPath:path, isDirectory:true)
        guard Bundle(url:root.appendingPathComponent(appPath))?.bundleIdentifier == appID else {
            throw failure("请将开源版监控和手机配对移到同一文件夹后重新打开。")
        }
        return root
    }

    static func attrs(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success else { return nil }
        return value
    }
    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    static func text(_ node: AXUIElement, _ key: String) -> String {
        attrs(node, key) as? String ?? ""
    }
    static func children(_ node: AXUIElement) -> [AXUIElement] {
        attrs(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    static func nodes(_ root: AXUIElement, stopAtWeb: Bool = false) -> [AXUIElement] {
        var stack = [root], result: [AXUIElement] = []
        var seen = Set<AXUIElement>()
        while let n = stack.popLast() {
            guard seen.insert(n).inserted else { continue }
            // AXChildren is a hierarchy; cap badly behaved providers.
            if result.count >= 2400 { break }
            result.append(n)
            let role = text(n, kAXRoleAttribute)
            if stopAtWeb && role == "AXWebArea" { continue }
            if ["AXTextField","AXSecureTextField","AXTextArea"].contains(role) { continue }
            stack.append(contentsOf: children(n).reversed().filter { !seen.contains($0) })
        }
        return result
    }
    static func rect(_ node: AXUIElement) -> CGRect? {
        guard let position = attrs(node, kAXPositionAttribute), let size = attrs(node, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &p),
              AXValueGetValue(size as! AXValue, .cgSize, &s), s.width > 0, s.height > 0 else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func officialApp(_ root: URL) -> NSRunningApplication? {
        let url = root.appendingPathComponent(appPath).resolvingSymlinksInPath().standardizedFileURL.path
        return NSRunningApplication.runningApplications(withBundleIdentifier: appID).first {
            !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == url
        }
    }
    static let accessibilityHelp = "请在 Mac「隐私与安全 → 辅助功能」允许手机配对的控制程序，再重开手机配对。"
    static func windowNodes(_ app: NSRunningApplication) throws -> [AXUIElement] {
        guard AXIsProcessTrusted() else { throw failure(accessibilityHelp) }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1.5)
        let windows = attrs(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard windows.count == 1, let w = windows.first, (attrs(w,"AXSheets") as? [AXUIElement] ?? []).isEmpty else {
            throw failure("请在 Mac 上显示正式监控主窗口，并关闭弹窗。")
        }
        return nodes(w)
    }
    static func button(_ name: String, _ nodes: [AXUIElement]) -> AXUIElement? {
        let matches = nodes.filter { n in
            text(n, kAXRoleAttribute) == kAXButtonRole &&
            [kAXDescriptionAttribute,kAXTitleAttribute].contains(where: {text(n,$0) == name})
        }
        return matches.count == 1 ? matches.first : nil
    }

    struct TicketList: Decodable {
        struct Ticket: Decodable {
            struct Contents: Decodable { let subject: String; let sentAt: String }
            let subject, timeLabel, day: String
            let state: InboxState
            let receivedConfirmedAt: Date?
            let content: Contents?
        }
        let version: Int
        let tickets: [Ticket]
    }
    static func ledgerURL() throws -> URL? {
        guard let selected = try selection(), !selected.title.isEmpty, !selected.bundle.isEmpty else {return nil}
        let name = "inbox-" + Rules.hash(selected.bundle + "/" + selected.title) + ".json"
        return Storage.root.appendingPathComponent(name)
    }
    static func summary() throws -> Payload {
        var tickets: [TicketList.Ticket] = []
        if let ledger = try ledgerURL(), files.fileExists(atPath: ledger.path) {
            do {
                let data = try Data(contentsOf: ledger)
                let parsed = try JSONDecoder().decode(TicketList.self, from: data)
                guard parsed.version == 2 else { throw failure("version") }
                tickets = parsed.tickets
            } catch { throw failure("正式监控的邮件队列暂时无法读取，请稍后刷新。") }
        }
        return ["pending": tickets.filter { !$0.state.terminal }.count,
                "uncertain": tickets.filter { $0.state == .uncertain && $0.receivedConfirmedAt == nil }.count,
                "tickets": tickets.suffix(60).reversed().map { item in
                    ["subject": item.content?.subject ?? item.subject,
                     "time": item.content?.sentAt ?? item.day + " " + item.timeLabel,
                     "state": item.receivedConfirmedAt == nil ? item.state.label : "本人已确认收到"]
                }]
    }

    static func ensureDirectory() throws {
        let privateDir = try privateDir()
        try files.createDirectory(at: privateDir, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let info = try files.attributesOfItem(atPath: privateDir.path)
        guard info[.type] as? FileAttributeType == .typeDirectory,
              (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((info[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
            throw failure("手机配对的私有数据目录权限无效。")
        }
    }
    struct Observation: Codable {
        let process: String, marker: String
        let seen, sampled: Date
        let progressed: Bool
    }
    static func observe(_ process: String, marker: String, previous: Observation?, now: Date) -> Observation {
        guard let p = previous, p.process == process,
              (0...25).contains(now.timeIntervalSince(p.sampled)) else {
            return Observation(process:process, marker:marker, seen:now, sampled:now, progressed:false)
        }
        let changed = p.marker != marker
        return Observation(process:process, marker:marker, seen:changed ? now : p.seen, sampled:now,
                           progressed:changed || p.progressed)
    }
    static func scanMarker(_ nodes: [AXUIElement]) -> (Int?, String?) {
        let items = nodes.filter { text($0,kAXRoleAttribute) == kAXStaticTextRole }
        let values = items.map { text($0,kAXValueAttribute) }
        var count: Int?
        for value in values {
            if let found = Rules.matches("^([0-9]+)\\s*次实际扫描$", value).first { count = Int(found[1]); break }
        }
        if count == nil, let title = items.first(where: {text($0,kAXValueAttribute) == "实际扫描"}) {
            var parent = element(attrs(title,kAXParentAttribute))
            for _ in 0..<3 {
                guard let n = parent else {break}
                let digits = self.nodes(n).compactMap { item -> Int? in
                    let s = text(item,kAXValueAttribute)
                    return text(item,kAXRoleAttribute) == kAXStaticTextRole ? Int(s) : nil
                }
                if digits.count == 1 { count = digits[0]; break }
                parent = element(attrs(n,kAXParentAttribute))
            }
        }
        let times = values.filter { !Rules.matches("^(?:上午|下午|AM |PM )?[0-9]{1,2}:[0-9]{2}:[0-9]{2}(?: AM| PM)?$", $0).isEmpty }
        return (count, times.count == 1 ? times[0] : nil)
    }

    static func status() throws -> Payload {
        let root = try project()
        var out = try summary()
        out["running"] = false; out["lastScan"] = "暂无实时扫描信息"
        guard let app = officialApp(root) else { out["monitorState"] = "正式监控应用未启动"; return out }
        let ax: [AXUIElement]
        do { ax = try windowNodes(app) }
        catch { out["monitorState"] = error.localizedDescription; return out }
        if button("取消等待",ax) != nil {out["monitorState"] = "正在连接监控机"; return out}
        if button("选择邮箱窗口",ax) != nil {out["monitorState"] = "请先在 Mac 选择邮箱窗口"; return out}
        if button("连接监控机 1",ax) != nil || button("开始监控",ax) != nil {out["monitorState"] = "监控已停止"; return out}
        guard button("停止监控",ax) != nil else {out["monitorState"] = "无法核实监控状态"; return out}
        let knownStates: Set<String> = ["连接等待授权","正在自动重连","等待邮箱前台","需要检查连接","通知通道待修复","仅扫描 · 推送暂停"]
        let observed = ax.filter {text($0,kAXRoleAttribute) == kAXStaticTextRole}.map {text($0,kAXValueAttribute)}
        let attention = observed.first(where: {knownStates.contains($0)})
        let (count,time) = scanMarker(ax)
        if let count {out["frames"] = count}
        if let time {out["lastScan"] = time}
        guard count != nil || time != nil else {
            out["monitorState"] = attention ?? "监控已开启；请在 Mac 打开监控台以核实扫描"
            return out
        }
        try ensureDirectory()
        let url = try privateDir().appendingPathComponent("scan-observation.json")
        let prev = (try? Data(contentsOf:url)).flatMap {try? JSONDecoder().decode(Observation.self,from:$0)}
        let marker = count.map(String.init) ?? time!
        let now = Date(), process = "\(app.processIdentifier)/\(app.launchDate?.timeIntervalSince1970 ?? 0)"
        let current = observe(process,marker:marker,previous:prev,now:now)
        try JSONEncoder().encode(current).write(to:url,options:.atomic)
        let live = current.progressed && now.timeIntervalSince(current.seen) < 20
        out["running"] = live
        out["monitorState"] = attention ?? (live ? "正在扫描" : "监控已开启，等待扫描进度更新")
        return out
    }

    @MainActor static func connect() async throws -> Payload {
        guard AXIsProcessTrusted() else { throw failure(accessibilityHelp) }
        let root = try project()
        var app = officialApp(root)
        if app == nil {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try await NSWorkspace.shared.openApplication(at:root.appendingPathComponent(appPath),configuration:config)
            try await Task.sleep(nanoseconds:700_000_000)
            app = officialApp(root)
        }
        guard let app else { throw failure("正式监控应用未就绪，请稍后重试。") }
        let ax = try windowNodes(app)
        if button("停止监控",ax) != nil {return ["message":"监控已开启，程序会自动恢复断开的会话。"]}
        if button("取消等待",ax) != nil {return ["message":"正在连接监控机 1。"]}
        guard button("选择邮箱窗口",ax) == nil else { throw failure("请先在 Mac 选择邮箱窗口并完成校准。") }
        guard let start = button("开始监控",ax) ?? button("连接监控机 1",ax), attrs(start,kAXEnabledAttribute) as? Bool == true,
              AXUIElementPerformAction(start,kAXPressAction as CFString) == .success else {
            throw failure("未找到可用的连接按钮。请在 Mac 查看正式监控的权限或弹窗。")
        }
        return ["message":"已提交连接，请刷新监控状态。"]
    }
}

@main enum Adapter {
    static func emit(_ payload: Payload) {
        if let data = try? JSONSerialization.data(withJSONObject:payload) { FileHandle.standardOutput.write(data) }
    }
    @MainActor static func main() async {
        umask(0o077)
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            switch args {
            case ["status"]: emit(try Host.status())
            case ["connect"]: emit(try await Host.connect())
            case ["frame"]: emit(try await MailboxFrame.frame())
            case ["self-test"]: emit(try MailboxFrame.selfTest())
            default:
                guard args.count == 4, args[0] == "tap", let x = Double(args[2]), let y = Double(args[3]) else {
                    throw failure("未知控制请求。")
                }
                emit(try await MailboxFrame.tap(args[1], x, y))
            }
        } catch { emit(["error":error.localizedDescription]); exit(1) }
    }
}
