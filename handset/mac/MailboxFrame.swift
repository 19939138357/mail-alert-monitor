import AppKit
import ApplicationServices
import CryptoKit
import ImageIO
import ScreenCaptureKit

@MainActor enum MailboxFrame {
    struct Browser {
        let pid: pid_t
        let title: String
        let window, web: AXUIElement
        let bounds, viewport: CGRect
    }
    struct Selection: Decodable { let title, bundle: String; let list, body: Region }
    struct Capture {
        let browser: Browser, window: SCWindow, image: CGImage
        let crop, list: CGRect
        let rows: [InboxRow]
        let jpeg: Data
        var digest: String { SHA256.hash(data: jpeg).map {String(format:"%02x",$0)}.joined() }
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x:browser.bounds.minX + p.x * browser.bounds.width / Double(image.width),
                    y:browser.bounds.minY + p.y * browser.bounds.height / Double(image.height))
        }
    }
    struct Stamp: Codable {
        let id, digest: String
        let pid: pid_t
        let windowID: UInt32
        let issued: Date
        let bounds, crop: CGRect
    }
    static func stampURL() throws -> URL { try Host.privateDir().appendingPathComponent("last-frame.json") }
    static let stale = "画面已更新或已过期。请刷新 Foxmail，再点选邮件。"

    static func targetURL(_ raw: String, address: String, title: String, approved: String) -> Bool {
        let full: String
        if raw.hasPrefix("https://") { full = raw }
        else {
            guard address.hasPrefix("https://"), String(address.dropFirst(8)) == raw else { return false }
            full = address
        }
        guard let url = URL(string: full) else { return false }
        return MailboxApproval.identity(url, title: title) == approved
    }
    static func consoleAvailable() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String:Any],
              session["kCGSSessionOnConsoleKey"] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true,
              let foreground = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return !["com.apple.SecurityAgent","com.apple.loginwindow","com.apple.systempreferences","com.apple.LocalAuthenticationRemoteService"].contains(foreground)
    }
    static func browser() throws -> Browser {
        guard consoleAvailable() else {throw failure("Mac 会话锁定或正在处理系统设置，请稍后重试。")}
        guard AXIsProcessTrusted() else {throw failure(Host.accessibilityHelp)}
        guard CGPreflightScreenCaptureAccess() else { throw failure("请在 Mac「隐私与安全 → 屏幕与系统音频录制」允许手机配对的控制程序，重开手机配对。") }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier:Host.safari).first else {
            throw failure("Safari 未打开，请先连接监控机 1。")
        }
        guard let approved = ProcessInfo.processInfo.environment["MAIL_MONITOR_FRAME_APPROVAL"], !approved.isEmpty else {
            throw failure("请在 Mac 的手机配对窗口选中共享已确认邮箱画面后重新开启连接。")
        }
        guard let selection = try Host.selection(), selection.shareableDigest == approved else {
            throw failure("请先在监控台选择 Safari 中的远程 Foxmail 窗口。")
        }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = Host.element(Host.attrs(ax,kAXFocusedWindowAttribute)),
              Host.text(window,kAXTitleAttribute) == selection.title, Host.attrs(window,kAXMinimizedAttribute) as? Bool != true,
              let bounds = Host.rect(window), (Host.attrs(window,"AXSheets") as? [AXUIElement] ?? []).isEmpty else {
            throw failure("请在 Safari 选中监控机 1 的邮箱标签，保持窗口展开。")
        }
        let nodes = Host.nodes(window,stopAtWeb:true)
        let address = nodes.first {Host.text($0,kAXIdentifierAttribute) == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"}
            .map {Host.text($0,kAXValueAttribute)} ?? ""
        let top = nodes.filter { Host.text($0,kAXRoleAttribute) == "AXWebArea" }
        guard top.count == 1, let web = top.first, let attr = Host.attrs(web,kAXURLAttribute),
              let url = (attr as? URL)?.absoluteString ?? (attr as? String), targetURL(url,address:address,title:selection.title,approved:approved),
              let viewport = Host.rect(web)?.intersection(bounds), viewport.width > 300, viewport.height > 210 else {
            throw failure("当前窗口无法确认为监控机 1 的远程会话。")
        }
        return Browser(pid:app.processIdentifier,title:selection.title,window:window,web:web,bounds:bounds,viewport:viewport)
    }
    static func same(_ a:Browser, _ b:Browser) -> Bool {
        a.pid == b.pid && a.title == b.title && CFEqual(a.window,b.window) && CFEqual(a.web,b.web) && a.bounds == b.bounds && a.viewport == b.viewport
    }
    static func screenshot(_ window: SCWindow) async throws -> CGImage {
        guard [window.frame.width, window.frame.height].allSatisfy({$0 >= 200 && $0 <= 6000}) else {
            throw failure("远程窗口尺寸不适合手机查看。")
        }
        let scale = min(2, 2400 / window.frame.width, 1800 / window.frame.height)
        let config = SCStreamConfiguration()
        config.width = Int((window.frame.width * scale).rounded())
        config.height = Int((window.frame.height * scale).rounded())
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:window),configuration:config)
    }
    static func data(_ image:CGImage, in area:CGRect) throws -> Data {
        guard let crop = image.cropping(to:area),
              let jpeg = NSBitmapImageRep(cgImage:crop).representation(using:.jpeg,properties:[.compressionFactor:0.78]),
              jpeg.count <= 4_000_000 else {throw failure("无法编码邮件画面。")}
        return jpeg
    }
    static func capture() async throws -> Capture {
        let b = try browser()
        let all = try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
        let matches = all.windows.filter {
            $0.owningApplication?.processID == b.pid && $0.owningApplication?.bundleIdentifier == Host.safari &&
                $0.title == b.title && $0.frame == b.bounds && $0.windowLayer == 0
        }
        guard matches.count == 1, let w = matches.first else {throw failure("没有找到唯一可见的监控机 1 窗口。")}
        let image = try await screenshot(w)
        let size = CGSize(width:image.width,height:image.height)
        let selection: Selection
        do {
            selection = try JSONDecoder().decode(Selection.self,from:Data(contentsOf:Storage.root.appendingPathComponent("settings.json")))
        } catch {throw failure("请先在正式监控连接监控机 1 并完成邮箱区域校准。")}
        guard selection.title == b.title, selection.bundle == Host.safari, selection.list.valid, selection.body.valid else {
            throw failure("当前正式监控的目标或邮箱选区不匹配。")
        }
        let lines = try recognize(image)
        let labels = lines.map {Rules.compact($0.text)}
        let toolbar = ["收取","回复","转发"].filter {word in labels.contains(where:{$0.contains(word)})}
        let security = ["请输入密码","输入您的密码","用户帐户控制","windows安全中心","enterpassword"]
        guard toolbar.count >= 2,
              labels.contains(where:{$0.localizedCaseInsensitiveContains("Foxmail") || $0.contains("收件箱")}),
              !labels.contains(where:{v in security.contains(where:{v.lowercased().contains($0)})}),
              let layout = MailboxLayout.regions(lines,size:size,list:selection.list,body:selection.body) else {
            throw failure("尚未核实 Foxmail 收件箱和预览区域，请显示有预览栏的收件箱。")
        }
        let list = layout.0.rect(size).integral, body = layout.1.rect(size).integral
        let crop = list.union(body)
        let vp = b.viewport.offsetBy(dx:-b.bounds.minX,dy:-b.bounds.minY)
            .applying(CGAffineTransform(scaleX:size.width/b.bounds.width,y:size.height/b.bounds.height))
        guard vp.contains(crop), let listImage = image.cropping(to:list) else {throw failure("邮箱选区超出了可验证的远程画面。")}
        let rows = UnreadList.rows(try recognize(listImage),dots:UnreadList.dots(listImage),now:Date())
        guard !rows.isEmpty, same(b,try browser()) else {throw failure("当前未能核实邮件列表，或窗口已切换。")}
        let jpeg = try data(image,in:crop)
        return Capture(browser:b,window:w,image:image,crop:crop,list:list,rows:rows,jpeg:jpeg)
    }

    static func withStampLock<T>(_ action:() throws -> T) throws -> T {
        try Host.ensureDirectory()
        let fd = open(try Host.privateDir().appendingPathComponent("frame.lock").path,O_NOFOLLOW|O_CREAT|O_RDWR,0o600)
        guard fd >= 0 else {throw failure("无法打开画面锁。")}
        defer {close(fd)}
        guard flock(fd,LOCK_EX) == 0 else {throw failure("无法核对画面状态。")}
        return try action()
    }
    static func frame() async throws -> Payload {
        let c = try await capture()
        let s = Stamp(id:UUID().uuidString,digest:c.digest,pid:c.browser.pid,windowID:c.window.windowID,
                      issued:Date(),bounds:c.browser.bounds,crop:c.crop)
        try withStampLock { try JSONEncoder().encode(s).write(to:stampURL(),options:.atomic) }
        return ["frameId":s.id,"jpeg":c.jpeg.base64EncodedString()]
    }
    static func isFresh(_ s:Stamp, _ id:String, at now:Date) -> Bool {
        let age = now.timeIntervalSince(s.issued)
        return s.id == id && age >= 0 && age <= 35
    }
    static func loadStamp(_ id:String) throws -> Stamp {
        guard UUID(uuidString:id) != nil,
              let bytes = try? Data(contentsOf:stampURL()), let s = try? JSONDecoder().decode(Stamp.self,from:bytes),
              isFresh(s,id,at:Date()) else {throw failure(stale)}
        return s
    }
    static func idle() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return flags.intersection([.maskShift,.maskControl,.maskAlternate,.maskCommand]).isEmpty &&
            !CGEventSource.buttonState(.combinedSessionState,button:.left) && !CGEventSource.buttonState(.combinedSessionState,button:.right) &&
            CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:CGEventType(rawValue:UInt32.max)!) > 1.5
    }
    static func hitWeb(_ b:Browser, _ p:CGPoint) -> Bool {
        guard b.viewport.contains(p) else {return false}
        var hit:AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(p.x),Float(p.y),&hit) == .success else {return false}
        for _ in 0..<14 {
            guard let n = hit else {return false}
            if CFEqual(n,b.web){return true}
            hit = Host.element(Host.attrs(n,kAXParentAttribute))
        }
        return false
    }
    static func rowForTap(_ rows:[InboxRow], at p:CGPoint, list:CGRect, height:CGFloat) throws -> InboxRow {
        guard list.contains(p) else {throw failure("请点选左侧邮件行，右侧为只读正文预览。")}
        let y = p.y - list.minY
        let distances = rows.sorted { abs($0.point.y-y) < abs($1.point.y-y) }
        let gap = zip(rows, rows.dropFirst()).map {abs($1.point.y-$0.point.y)}.filter {$0>4}.min() ?? height*0.045
        guard let row = distances.first, abs(row.point.y-y) <= min(gap*0.54,height*0.033) else {
            throw failure("这里没有可核实的邮件行，请点发件人所在行。")
        }
        guard !row.unread else {throw failure("这封邮件还未读，请等自动监控完成推送后再点开。")}
        return row
    }
    static func confirmDelivered(_ row: InboxRow, in tickets: [InboxTicket], now: Date) throws {
        // A missed blue dot must never make an unread mail eligible for a manual tap.
        // Require a unique matching receipt, using the same identity rules as the monitor.
        guard !tickets.contains(where: {$0.state == .reading}) else {
            throw failure("监控正在读取邮件正文，请等推送完成后再选择邮件。")
        }
        let matches = tickets.filter { $0.day == row.day && $0.matchesRow(row,now:now) }
        guard matches.count == 1, let item = matches.first, item.content != nil,
              item.state == .accepted || item.receivedConfirmedAt != nil else {
            throw failure("这封邮件尚无唯一可核实的推送记录，请选择已推送的已读邮件。")
        }
    }
    static func tap(_ id:String, _ x:Double, _ y:Double) async throws -> Payload {
        guard x.isFinite,y.isFinite,(0..<1).contains(x),(0..<1).contains(y) else {throw failure("点击位置无效。")}
        let s = try withStampLock {try loadStamp(id)}
        let c = try await capture()
        guard c.browser.pid == s.pid,c.window.windowID == s.windowID,c.browser.bounds == s.bounds,c.crop == s.crop,c.digest == s.digest else {throw failure(stale)}
        let p = CGPoint(x:c.crop.minX + x*c.crop.width,y:c.crop.minY + y*c.crop.height)
        let row = try rowForTap(c.rows,at:p,list:c.list,height:Double(c.image.height))
        guard let ledgerURL = try Host.ledgerURL(), let bytes = try? Data(contentsOf:ledgerURL),
              let ledger = try? JSONDecoder().decode(InboxLedger.self,from:bytes), ledger.version == 2 else { throw failure("邮件队列无法核对，请稍后重试。") }
        try confirmDelivered(row,in:ledger.tickets,now:Date())
        let hit = c.point(CGPoint(x:c.list.minX + row.point.x,y:c.list.minY + row.point.y))
        guard idle(),NSWorkspace.shared.frontmostApplication?.processIdentifier == c.browser.pid else {
            throw failure("请保持监控机 1 的 Safari 窗口在前台，并暂停本机鼠标键盘操作后重试。")
        }
        // OCR and image transmission can take several seconds. Re-capture without OCR
        // immediately before input and require identical authenticated view bytes.
        guard same(c.browser,try browser()),hitWeb(c.browser,hit),
              let move = CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:hit,mouseButton:.left) else {throw failure(stale)}
        // Guacamole sends its remote cursor position on mousemove, before mouseDown.
        move.flags = []
        move.post(tap:.cghidEventTap)
        try await Task.sleep(nanoseconds:1_650_000_000)
        let fresh = try await screenshot(c.window)
        guard fresh.width == c.image.width, fresh.height == c.image.height, try data(fresh,in:c.crop) == c.jpeg else {throw failure(stale)}
        try withStampLock {
            _ = try loadStamp(id)
            guard same(c.browser,try browser()),NSWorkspace.shared.frontmostApplication?.processIdentifier == c.browser.pid,
                  idle(),hitWeb(c.browser,hit),let cursor = CGEvent(source:nil)?.location,
                  abs(cursor.x - hit.x) < 2, abs(cursor.y - hit.y) < 2,
                  let down = CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:hit,mouseButton:.left),
                  let up = CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:hit,mouseButton:.left) else {
                throw failure("目标已变更或被遮挡，请刷新。")
            }
            try Host.files.removeItem(at:stampURL())
            down.setIntegerValueField(.mouseEventClickState,value:1)
            up.setIntegerValueField(.mouseEventClickState,value:1)
            down.flags = []; up.flags = []
            down.post(tap:.cghidEventTap); usleep(80_000); up.post(tap:.cghidEventTap)
        }
        return ["message":"已向 Foxmail 发送选中请求，请刷新画面确认。"]
    }

    static func selfTest() throws -> Payload {
        func test(_ ok:Bool) throws {if !ok {throw failure("控制边界自测失败。")}}
        let title = "Remote Foxmail"
        let base = "https://portal.example.org:9978/baoleiji/"
        let allowed = base + "?session=synthetic#/client/A"
        let digest = MailboxApproval.identity(URL(string: allowed)!, title: title)!
        try test(targetURL(allowed,address:"",title:title,approved:digest))
        try test(targetURL(String(allowed.dropFirst(8)),address:allowed,title:title,approved:digest))
        try test(!targetURL(allowed,address:"",title:"Other mailbox",approved:digest))
        try test(!targetURL(allowed,address:"",title:title,approved:""))
        for invalid in [base, base + "?session=synthetic#/client/B", base + "?session=different#/client/A",
                        "http://portal.example.org/", "https://user@portal.example.org/", "https://example.com/"] {
            try test(!targetURL(invalid,address:"",title:title,approved:digest))
        }
        let now = Date(), box = CGRect(x:20,y:40,width:180,height:300)
        let s = Stamp(id:"id",digest:"abc",pid:1,windowID:1,issued:now,bounds:box,crop:box)
        try test(isFresh(s,"id",at:now) && !isFresh(s,"other",at:now) && !isFresh(s,"id",at:now.addingTimeInterval(36)) && !isFresh(s,"id",at:now.addingTimeInterval(-1)))
        let first = Host.observe("1",marker:"23",previous:nil,now:now)
        let second = Host.observe("1",marker:"24",previous:first,now:now)
        try test(!first.progressed && second.progressed && !Host.observe("2",marker:"25",previous:second,now:now).progressed)
        try test(!Host.observe("1",marker:"25",previous:second,now:now.addingTimeInterval(1000)).progressed)
        let read = InboxRow(sender:"Demo",subject:"Demo",timeLabel:"10:00",day:"demo",unread:false,point:CGPoint(x:20,y:51))
        var unread = read; unread.unread = true
        let loc = CGPoint(x:100,y:91)
        try test((try? rowForTap([read],at:loc,list:box,height:600)) != nil)
        try test((try? rowForTap([unread],at:loc,list:box,height:600)) == nil)
        try test((try? rowForTap([read],at:.zero,list:box,height:600)) == nil)
        try test((try? confirmDelivered(read,in:[],now:now)) == nil)
        var item = InboxTicket(id:"t",rowKey:read.key,sender:read.sender,subject:read.subject,timeLabel:read.timeLabel,
                               day:read.day,occurrence:0,discovered:now)
        try test((try? confirmDelivered(read,in:[item],now:now)) == nil)
        item.content = MailContent(fingerprint:"demo",subject:"Demo",text:"sample",sentAt:"10:00")
        item.state = .accepted
        try test((try? confirmDelivered(read,in:[item],now:now)) != nil)
        try test((try? confirmDelivered(read,in:[item,item],now:now)) == nil)
        return ["passed":true]
    }
}
