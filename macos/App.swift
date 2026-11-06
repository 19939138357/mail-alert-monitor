import SwiftUI
import AppKit
import ScreenCaptureKit
import ApplicationServices
import ImageIO
import Darwin

struct Settings: Codable {
    var list=Region(x:0.20,y:0.12,w:0.36,h:0.78)
    var body=Region(x:0.56,y:0.12,w:0.43,h:0.84)
    var night=true
    var autoOpen=true
    var title=""
    var bundle=""
    var includeExistingUnread=true
    var approvedPage:String?
    var browseEntireList=false
    init(){}
    enum CodingKeys:String,CodingKey {case list,body,night,autoOpen,title,bundle,includeExistingUnread,browseEntireList,approvedPage}
    init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        list=try c.decodeIfPresent(Region.self,forKey:.list) ?? list;body=try c.decodeIfPresent(Region.self,forKey:.body) ?? body
        night=try c.decodeIfPresent(Bool.self,forKey:.night) ?? true;autoOpen=try c.decodeIfPresent(Bool.self,forKey:.autoOpen) ?? true
        title=try c.decodeIfPresent(String.self,forKey:.title) ?? "";bundle=try c.decodeIfPresent(String.self,forKey:.bundle) ?? ""
        includeExistingUnread=try c.decodeIfPresent(Bool.self,forKey:.includeExistingUnread) ?? true
        approvedPage=try c.decodeIfPresent(String.self,forKey:.approvedPage)
        browseEntireList=false // Retired: never tour read-mail history.
    }
}
enum SystemPortal {
    static let url=URL(string:"https://portal.example.com:9978/admin.php?controller=admin_index&action=login")!
    // Only a distributor that has adapted the portal and its origin/identity checks
    // should enable the dedicated sign-in flow. The public build uses a chosen window.
    static let isAdapted = false
    static let browserID="com.apple.Safari"
}
@MainActor final class Monitor: ObservableObject {
    @Published var windows: [SCWindow]=[]
    @Published var selection: UInt32=0
    @Published var settings=Settings()
    @Published var token=""
    @Published var hasToken=false
    @Published var tokenSaving=false
    @Published var running=false
    @Published var busy=false
    @Published var openingSystem=false
    @Published var connectionStep=0
    @Published var mailReady=false
    @Published var hasSystemCredentials=false
    @Published var showSystemSettings=false
    @Published var systemUsername=""
    @Published var systemPassword=""
    @Published var systemSaving=false
    @Published var systemError=""
    @Published var status="在 Safari 打开远程 Foxmail 收件箱，然后选择邮箱窗口。"
    @Published var log: [String]=[]
    @Published var preview: NSImage?
    @Published var regionMode=0
    @Published var drag: CGRect?
    @Published var offline=false
    @Published var screenshotName=""
    @Published var offlineList=Region(x:0,y:0,w:1,h:1)
    @Published var offlineDetails=""
    var previewList:Region {offline ? offlineList:settings.list}
    @Published var linesCount=0
    @Published var frames=0
    @Published var queuedCount=0
    @Published var uncertainCount=0
    @Published var lastScan="尚未扫描"
    @Published var screenAllowed=CGPreflightScreenCaptureAccess()
    @Published var accessibility=AXIsProcessTrusted()
    @Published var ocrSummary="邮件正文会保存在本机队列中。"
    var task: Task<Void,Never>?
    var connectionTask: Task<Void,Never>?
    var connectionGeneration=0
    @Published var reconnecting=false
    @Published var portalNeedsUnlock=false
    @Published var unlockingPortal=false
    var recovery=ReconnectPolicy()
    var recoveryTask:Task<Void,Never>?
    var recoveryProcess:Process?
    var portalSecret:PortalCredentials?
    var portalReadGate=SecretReadGate()
    var automaticLoginSubmitted=false
    var recoveryPortalOpened=false
    var missingMailboxFrames=0
    var lastRemoteHealthCheck=Date.distantPast
    var imageGeneration=0
    var generation=0
    @Published var inbox=InboxLedger()
    var readingMail:ReadingMail?
    var listSignature=""
    var stableListFrames=0
    var firstInboxSnapshot=true
    var pageBeforeScroll:String?
    var pagerFrames=0
    var lastPageTurn=Date.distantPast
    var listAtTop=true
    var frameRect: CGRect?
    var lastFrameAt: Date?
    var ledgerURL: URL?
    @Published var transportPaused=false
    @Published var testInFlight=false
    @Published var notificationNeedsUnlock=false
    @Published var unlockingNotifications=false
    @Published var notificationSecret:String?
    @Published var showNotificationWarning=false
    @Published var notificationReminderMuted=false
    var notificationAlertPolicy=NotificationAlertPolicy()
    var notificationHealthTask:Task<Void,Never>?
    var notificationAttention:Int?
    var notificationReadGate=SecretReadGate()
    var lockFD: Int32 = -1
    var startupError: String?
    var lastActivation=Date.distantPast
    var lastReadRetry:[String:Date]=[:]
    var listOCRCache=FrameOCRCache()
    var bodyOCRCache=FrameOCRCache()
    var lastLayoutCheck=Date.distantPast
    init() {
        do {
            try Storage.prepare()
            lockFD=open(Storage.root.appendingPathComponent("instance.lock").path,O_CREAT|O_RDWR,0o600)
            guard lockFD>=0 else{throw failure("无法建立单实例锁")}
            if flock(lockFD,LOCK_EX|LOCK_NB) != 0 {
                let existing=NSRunningApplication.runningApplications(withBundleIdentifier:"org.example.mailalertmonitor").first{$0.processIdentifier != ProcessInfo.processInfo.processIdentifier}
                existing?.activate();exit(0)
            }
            let path=Storage.root.appendingPathComponent("settings.json")
            if FileManager.default.fileExists(atPath:path.path) {
                settings=try JSONDecoder().decode(Settings.self,from:Data(contentsOf:path))
                guard settings.list.valid,settings.body.valid else { throw failure("区域配置无效，请保留 settings.json 并检查。") }
            }
            hasToken = Secrets.isConfigured()
            hasSystemCredentials = PortalVault.configured()
        } catch { startupError=error.localizedDescription;status=error.localizedDescription }
    }
    func note(_ value: String) {
        status=value
        let line=Rules.dateFormat("yyyy-MM-dd HH:mm:ss").string(from:Date())+"  "+value
        log.append(line);if log.count>120 {log.removeFirst(log.count-120)}
        // Only fixed status messages go to disk; never OCR bodies, tokens or codes.
        let url=Storage.root.appendingPathComponent("monitor.log")
        if let data=(line+"\n").data(using:.utf8) {
            if let size=(try? FileManager.default.attributesOfItem(atPath:url.path)[.size] as? NSNumber),size.intValue>1_000_000 { try? data.write(to:url,options:.atomic) }
            else if let handle=try? FileHandle(forWritingTo:url) { defer{try? handle.close()};_ = try? handle.seekToEnd();try? handle.write(contentsOf:data) }
            else { try? data.write(to:url,options:.atomic) }
            try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        }
    }
    func permissions() {
        screenAllowed=CGPreflightScreenCaptureAccess();accessibility=AXIsProcessTrusted()
    }
    var notificationAvailability:NotificationAvailability {
        NotificationAvailability.resolve(configured:hasToken,hasSecret:notificationSecret?.isEmpty == false,
            needsAuthorization:notificationNeedsUnlock,authorizing:unlockingNotifications,rejected:transportPaused)
    }
    var notificationWarningTitle:String {
        notificationAvailability.requiresAttention ? notificationAvailability.title:"有通知发送结果待核对"
    }
    var notificationWarningDetail:String {
        notificationAvailability.requiresAttention ? notificationAvailability.detail:
            "有 \(uncertainCount) 封通知尚未确认发送结果，保留原记录且不会自动重发；其他新邮件继续独立处理。请查看运行记录。"
    }
    func clearNotificationAttention() {
        if let notificationAttention{NSApp.cancelUserAttentionRequest(notificationAttention)}
        notificationAttention=nil
    }
    func silenceNotificationReminder() {
        notificationAlertPolicy.silence();notificationReminderMuted=true
        clearNotificationAttention();showNotificationWarning=false
    }
    func confirmInboxReceived(_ id:String) {
        guard let ticket=inbox.tickets.first(where:{$0.id==id && $0.state == .uncertain && $0.receivedConfirmedAt==nil}),let content=ticket.content else{return}
        let alert=NSAlert();alert.messageText="已在手机核对这条通知？"
        alert.informativeText=content.sentAt+"\n"+content.subject+"\n\n只有在手机上找到这封邮件对应的通知后才确认。确认仅解除这条旧提醒，保留原发送记录，不会补发。"
        alert.addButton(withTitle:"已在手机核对收到");alert.addButton(withTitle:"取消")
        // The safe default must not manufacture a receipt on Return.
        alert.buttons[0].keyEquivalent="";alert.buttons[1].keyEquivalent="\r"
        guard alert.runModal() == .alertFirstButtonReturn,let url=ledgerURL else{return}
        var updated=inbox
        guard updated.confirmReceived(id,now:Date()) else{return}
        do {
            try Storage.write(updated,to:url)
            inbox=updated;queuedCount=inbox.waiting;uncertainCount=inbox.uncertain
            updateNotificationHealth();note("已记录本人对一条历史通知的手机收件确认，原发送去重记录保留。")
        }catch{note("收件确认保存失败，原待核对记录保留。")}
    }
    func updateNotificationHealth() {
        let availability=notificationAvailability
        let incident=running ? (availability.requiresAttention ? "channel/\(availability)":(uncertainCount>0 ? "uncertain/\(uncertainCount)":nil)):nil
        guard let incident else {
            notificationAlertPolicy.reset();notificationReminderMuted=false
            clearNotificationAttention();NSApp.dockTile.badgeLabel=nil;showNotificationWarning=false
            return
        }
        NSApp.dockTile.badgeLabel="!"
        if notificationAlertPolicy.shouldAlert(incident:incident,now:Date()) {
            notificationReminderMuted=false;showNotificationWarning=true
            NSSound.beep()
            clearNotificationAttention()
            notificationAttention=NSApp.requestUserAttention(.informationalRequest)
            note(notificationWarningTitle+"。"+notificationWarningDetail)
        }
    }
    func watchNotificationHealth() {
        notificationHealthTask?.cancel()
        updateNotificationHealth()
        notificationHealthTask=Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds:1_000_000_000)
                guard !Task.isCancelled,let self,self.running else{return}
                self.updateNotificationHealth()
            }
        }
    }
    func connectSystem() {
        guard SystemPortal.isAdapted,!openingSystem,!running,!busy,!systemSaving else{return}
        connectionTask=Task{await openSystem()}
    }
    func cancelConnection() {
        guard openingSystem else{return}
        connectionGeneration+=1;connectionTask?.cancel();connectionTask=nil
        if recoveryProcess?.isRunning == true{recoveryProcess?.terminate()};recoveryProcess=nil
        openingSystem=false;connectionStep=0
        note("已取消连接等待。已提交的登录不能撤回；程序不会继续点击入口或启动监控。")
    }
    func connectionValid(_ epoch:Int)->Bool {openingSystem && connectionGeneration==epoch && !Task.isCancelled}
    func openSystem() async {
        guard !openingSystem,!running,!busy else{return}
        permissions()
        guard screenAllowed else{requestScreen();return}
        guard accessibility else{requestAccessibility();return}
        openingSystem=true;connectionGeneration+=1;let epoch=connectionGeneration;connectionStep=1
        note("正在打开 Safari，核对监控机 1 的连接状态。")
        let watchdog=Task {
            try? await Task.sleep(nanoseconds:75_000_000_000)
            if !Task.isCancelled,self.connectionValid(epoch) {
                self.cancelConnection()
                self.note("连接等待已超时。请检查 Safari 或本机授权弹窗，再点击连接重试。")
            }
        }
        defer{watchdog.cancel();if connectionGeneration==epoch{openingSystem=false;connectionStep=0}}
        guard let safari=NSWorkspace.shared.urlForApplication(withBundleIdentifier:SystemPortal.browserID) else {
            note("未找到 Safari，请确认系统浏览器已安装。");return
        }
        do {
            let config=NSWorkspace.OpenConfiguration();config.activates=true
            _ = try await NSWorkspace.shared.openApplication(at:safari,configuration:config)
            guard connectionValid(epoch) else{return}
            if SafariDevice.state() == .other{_ = SafariDevice.restoreRemoteTab() || SafariDevice.restorePortalTab()}
            if SafariDevice.state() == .other {
                _=try await NSWorkspace.shared.open([SystemPortal.url],withApplicationAt:safari,configuration:config)
                for _ in 0..<5 {
                    try await Task.sleep(nanoseconds:1_000_000_000)
                    guard connectionValid(epoch) else{return}
                    if SafariDevice.state() != .other{break}
                }
            }
            if [.other,.login].contains(SafariDevice.state()) {
                guard hasSystemCredentials else{note("请先保存系统账号，随后可一键连接监控机 1。");showSystemSettings=true;return}
                note("正在读取本机保存的系统账号。若出现钥匙串授权弹窗，请在弹窗中确认。")
                let credentials=try await Task.detached{try PortalVault.read()}.value
                guard connectionValid(epoch) else{return}
                portalSecret=credentials;portalNeedsUnlock=false
                note("正在登录系统，随后从监控机 1 左侧浏览器按钮进入邮箱。")
                var probe="WAIT"
                for _ in 0..<5 {
                    guard connectionValid(epoch) else{return}
                    probe=await runPageAction(try SafariLogin.recoveryScript(nil),valid:{self.connectionValid(epoch)})
                    if ["READY","SIGNED_IN","MANUAL"].contains(probe){break}
                    try await Task.sleep(nanoseconds:1_000_000_000)
                }
                let result=probe=="READY" ? await runPageAction(try SafariLogin.recoveryScript(credentials),valid:{self.connectionValid(epoch)}):probe
                guard connectionValid(epoch) else{return}
                guard result=="SIGNED_IN" || result=="SUBMITTED" else{note(SafariLogin.message(result));return}
            }
            var clicked=false,verifiedFrames=0
            for _ in 0..<25 {
                guard connectionValid(epoch) else{return}
                if SafariDevice.state() == .remote,!SafariDevice.interrupted() {
                    connectionStep=3;tell("远程页面已打开，正在等待并连续核对 Foxmail 画面。")
                    await refresh()
                    guard connectionValid(epoch) else{return}
                    if let target=windows.first(where:{$0.owningApplication?.bundleIdentifier==SystemPortal.browserID && $0.title=="administrator@192.0.2.11"}) {
                        selection=target.windowID;offline=false
                        await previewOnce()
                        guard connectionValid(epoch) else{return}
                        verifiedFrames=(preview != nil && linesCount>0 && mailReady) ? verifiedFrames+1:0
                        if verifiedFrames>=2{start();return}
                    }
                }
                if !clicked,SafariDevice.state() == .devices {
                    connectionStep=2
                    try await enterDevice(valid:{self.connectionValid(epoch)});clicked=true
                    note("已点击监控机 1 工具栏左侧浏览器按钮，正在连接邮箱。")
                }
                try await Task.sleep(nanoseconds:1_000_000_000)
            }
            note("连接未完成，请检查 Safari 的登录或远程连接页面；本次不会重复点击。")
        } catch {if connectionValid(epoch){note("进入监控机 1 未完成："+error.localizedDescription)}}
    }
    func saveSystemCredentials() async {
        guard !systemSaving,!openingSystem else{return}
        let credentials=PortalCredentials(username:systemUsername.trimmingCharacters(in:.whitespacesAndNewlines),password:systemPassword)
        guard credentials.valid else{systemError="请输入完整的系统账号和口令。";return}
        systemSaving=true;systemError=""
        do {
            try await Task.detached{try PortalVault.save(credentials)}.value
            portalSecret=credentials;portalNeedsUnlock=false
            hasSystemCredentials=true;systemPassword="";systemUsername="";showSystemSettings=false
            note("系统账号已保存到本机钥匙串。")
            systemSaving=false
            await openSystem()
        }catch{systemSaving=false;systemError="保存失败，请检查系统钥匙串授权后重试。"}
    }
    func requestScreen() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        note("请在系统设置中允许“抽查邮件监控”录屏，然后刷新窗口；必要时退出重开。")
    }
    func requestAccessibility() {
        let key=kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _=AXIsProcessTrustedWithOptions([key:true] as CFDictionary)
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        note("请在系统设置中允许“抽查邮件监控”辅助功能，供自动单击新邮件使用。")
    }
    func refresh() async {
        guard !running,startupError==nil else{return};permissions()
        do {
            let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
            windows=content.windows.filter { $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.windowLayer==0 && $0.frame.width>250 && $0.frame.height>180 && !($0.title ?? "").isEmpty }.sorted{label($0)<label($1)}
            if !windows.contains(where:{$0.windowID==selection}) {
                let matches=windows.filter{$0.title==settings.title && $0.owningApplication?.bundleIdentifier==settings.bundle}
                selection=matches.count==1 ? matches[0].windowID:0
            }
            note(windows.isEmpty ? "未找到可监控窗口，请打开远程邮箱并检查录屏权限。":"窗口列表已刷新，请选择远程邮箱窗口。")
        } catch { note("读取窗口失败，请检查录屏权限并重新打开应用。") }
    }
    func label(_ w: SCWindow)->String { "\(w.owningApplication?.applicationName ?? "应用") · \(w.title ?? "窗口")" }
    func save() throws {
        guard settings.list.valid,settings.body.valid else{throw failure("识别区域过小或超出画面")}
        try Storage.write(settings,to:Storage.root.appendingPathComponent("settings.json"))
    }
    func saveToken() async {
        guard !running,!testInFlight,!tokenSaving,!openingSystem,!unlockingNotifications else{return}
        let value=token.trimmingCharacters(in:.whitespacesAndNewlines)
        tokenSaving=true;defer{tokenSaving=false}
        note("正在保存微信配置；若出现本机钥匙串授权，请在系统弹窗中确认。")
        do {
            try await Task.detached{try Secrets.save(value)}.value;token="";hasToken=true;transportPaused=false
            notificationReadGate.invalidate();notificationSecret=nil;notificationNeedsUnlock=false
            for i in inbox.tickets.indices where inbox.tickets[i].state == .rejected {inbox.tickets[i].state = .queued}
            if ledgerURL != nil{try persistInbox()}
            try save();note("微信 Token 已保存。明确被拒绝的邮件已重新排队；结果不确定的通知不会自动重复发。")
        }
        catch{note(error.localizedDescription)}
    }
    func testPush() async {
        guard !running,!testInFlight else{return};testInFlight=true;defer{testInFlight=false}
        note("正在读取本机微信配置；若出现钥匙串授权弹窗，请在弹窗中确认。")
        do {
            let secret=try await Task.detached{try Secrets.read()}.value;guard !secret.isEmpty else{throw failure("请先保存微信 Token")}
            note("正在发送你请求的微信测试通知…")
            let outcome=await push(token:secret,title:"Mac 监控测试",body:"本条为手动测试，请确认微信收到。",alarm:settings.night)
            note(outcome=="Accepted" ? "测试通知已被服务受理，请在手机确认收件和响铃。":"测试未确认成功，请检查通道；不会自动重发。")
        } catch {note(error.localizedDescription)}
    }
    func unlockNotifications() async {
        guard !unlockingNotifications,!testInFlight,!tokenSaving else{return}
        unlockingNotifications=true;defer{unlockingNotifications=false}
        notificationReadGate.invalidate();notificationNeedsUnlock=true
        note("请在本机钥匙串窗口确认通知授权；新未读继续排队，暂不自动打开。")
        do {
            let secret=try await Task.detached{try Secrets.read()}.value
            guard !secret.isEmpty else {
                hasToken=false;notificationNeedsUnlock=false
                note("微信配置未找到。请停止监控后在通知与设置中保存配置。");return
            }
            notificationSecret=secret;notificationNeedsUnlock=false
            note("通知授权已可用，继续发送保存的完整正文。")
        }catch{note("通知配置读取未完成："+error.localizedDescription+"。邮件已保留。")}
    }
    func loadNotificationSecret() {
        guard notificationSecret == nil,!notificationNeedsUnlock,
              let id=notificationReadGate.begin(now:Date()) else{return}
        tell("正在检查微信推送配置；新未读继续排队，配置可用后再自动打开。")
        // Never await a synchronous keychain service from the scan loop.
        // A late probe cannot replace a new token or explicit authorization.
        Task { [weak self] in
            let result=await Task.detached { () -> Result<String,Error> in
                do{return .success(try Secrets.read(interactive:false))}
                catch{return .failure(error)}
            }.value
            guard let self,self.notificationReadGate.finish(id) else{return}
            switch result {
            case .success(let secret) where !secret.isEmpty:
                self.notificationSecret=secret
                if self.running{self.note("通知授权已可用，继续发送保存的完整正文。")}
            case .success:
                self.hasToken=false;self.notificationNeedsUnlock=false
                self.note("微信配置未找到。请停止监控后在通知与设置中保存配置。")
            case .failure(let error):
                self.notificationNeedsUnlock=true
                self.note("通知配置读取失败："+error.localizedDescription+"。请点“授权通知”；新未读只排队，暂不自动打开。")
            }
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds:5_000_000_000)
            guard let self,self.notificationReadGate.expire(id,now:Date()) else{return}
            self.notificationNeedsUnlock=true
            self.note("通知配置读取超过等待时间；请点“授权通知”。新未读只排队，暂不自动打开。")
        }
    }
    func currentWindow() async throws -> SCWindow {
        var content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
        if running,settings.autoOpen,!(content.windows.contains{$0.windowID==selection && $0.title==settings.title}),await restoreMailboxWhenIdle() {
            content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
            let matches=content.windows.filter{$0.title==settings.title && $0.owningApplication?.bundleIdentifier==SystemPortal.browserID}
            if matches.count==1,let recovered=matches.first{selection=recovered.windowID;windows=content.windows;note("已恢复原邮箱标签页，继续处理保存的未读任务。")}
        }
        guard let window=content.windows.first(where:{$0.windowID==selection}),window.frame.width>100,window.frame.height>100 else {throw failure("目标窗口已关闭或最小化，请恢复窗口。")}
        if running, (window.title ?? "") != settings.title || window.owningApplication?.bundleIdentifier != settings.bundle {throw failure("目标窗口已切换。请回到所选邮箱。")}
        if running,!SystemPortal.isAdapted {
            guard let approved=settings.approvedPage,PublicMailbox.inspect(window)?.digest==approved else {
                throw failure("请保持已授权的 Safari 邮箱标签打开，页面地址变化后请停止并重新选择。")
            }
        }
        return window
    }
    func restoreMailboxWhenIdle() async ->Bool {
        guard SystemPortal.isAdapted,running,settings.autoOpen,settings.bundle==SystemPortal.browserID,
              settings.title=="administrator@192.0.2.11",AXIsProcessTrusted(),Date().timeIntervalSince(lastActivation)>8,
              CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:CGEventType(rawValue:UInt32.max)!)>2,
              CGEventSource.flagsState(.combinedSessionState).intersection([.maskShift,.maskControl,.maskAlternate,.maskCommand]).isEmpty,
              !CGEventSource.buttonState(.combinedSessionState,button:.left),!CGEventSource.buttonState(.combinedSessionState,button:.right),
              let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:SystemPortal.browserID) else{return false}
        let front=NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard !["com.apple.SecurityAgent","com.apple.loginwindow","com.apple.systempreferences"].contains(front) else{return false}
        lastActivation=Date()
        do {
            let config=NSWorkspace.OpenConfiguration();config.activates=true
            _=try await NSWorkspace.shared.openApplication(at:url,configuration:config)
            guard running else{return false}
            return SafariDevice.restoreRemoteTab()
        }catch{return false}
    }
    func capture(_ window: SCWindow) async throws -> CGImage {
        let filter=SCContentFilter(desktopIndependentWindow:window)
        let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2)
        config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
    }
    func previewOnce() async {
        guard !busy,!running,selection != 0 else{return};busy=true;defer{busy=false}
        do {
            let w=try await currentWindow();let image=try await capture(w)
            let result=try await Task.detached{try recognize(image)}.value
            offline=false;preview=NSImage(cgImage:image,size:w.frame.size)
            mailReady=Self.isMailboxFrame(result)
            if !mailReady {
                let labels=result.map(\.text).filter{$0.localizedCaseInsensitiveContains("mail") || $0.contains("箱") || $0.contains("排序") || $0.contains("收取") || $0.contains("回复") || $0.contains("转发")}
                tell("正在核对邮箱界面标识："+labels.joined(separator:" / "))
            }
            linesCount=result.count;lastScan=DateFormatter.localizedString(from:Date(),dateStyle:.none,timeStyle:.medium)
            ocrSummary="本次识别 \(result.count) 行；完整抽查标题 \(result.reduce(0){$0+Rules.titles($1.text).count}) 处。"
            note("预览与本机 OCR 已完成，可在画面上拖选列表和正文区域。")
        } catch {preview=nil;linesCount=0;mailReady=false;note("预览失败："+error.localizedDescription)}
    }
    func importScreenshot(_ url: URL? = nil) async {
        guard !running,!busy else{return}
        var selected=url
        if selected==nil {
            let panel=NSOpenPanel();panel.allowedContentTypes=[.png,.jpeg,.tiff];panel.allowsMultipleSelection=false
            panel.directoryURL=FileManager.default.urls(for:.picturesDirectory,in:.userDomainMask).first
            guard panel.runModal() == .OK else{return};selected=panel.url
        }
        guard let selected else{return}
        busy=true;imageGeneration+=1;let epoch=imageGeneration
        note("正在读取截图并进行本机识别…")
        let watchdog=Task {
            try? await Task.sleep(nanoseconds:30_000_000_000)
            if !Task.isCancelled,self.imageGeneration==epoch,self.busy {
                self.imageGeneration+=1;self.busy=false
                self.note("图片读取超时。请检查系统文件访问提示，或改用导入截图选择本机图片。")
            }
        }
        defer{watchdog.cancel();if imageGeneration==epoch{busy=false}}
        do {
            let cg=try await Task.detached { () throws -> CGImage in
                let data=try Data(contentsOf:selected,options:.mappedIfSafe)
                guard data.count<=40_000_000,let source=CGImageSourceCreateWithData(data as CFData,nil),
                      let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                      let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,
                      width>0,height>0,width<=16000,height<=16000,width*height<=32_000_000,
                      let cg=CGImageSourceCreateImageAtIndex(source,0,nil) else{throw failure("图片无效或过大，请选择普通邮箱截图。")}
                return cg
            }.value
            guard imageGeneration==epoch else{return}
            offline=true;offlineList=Region(x:0,y:0,w:1,h:1);preview=NSImage(cgImage:cg,size:CGSize(width:cg.width,height:cg.height));screenshotName=selected.lastPathComponent
            let result=try await Task.detached{(try recognize(cg),UnreadList.dots(cg))}.value
            guard imageGeneration==epoch else{return}
            let rows=UnreadList.rows(result.0,dots:result.1,now:Date())
            linesCount=result.0.count
            lastScan="历史截图 · 只读回放"
            ocrSummary="识别 \(result.0.count) 行，完整邮件 \(rows.count) 封，其中未读 \(rows.filter(\.unread).count) 封。边缘不完整邮件需滚动后核对。"
            offlineDetails=rows.map{($0.unread ? "未读 · ":"已读 · ")+$0.subject}.joined(separator:"  |  ")
            // An old screenshot is never fed to the live ledger or transport.
            note("截图验证完成："+ocrSummary)
        }catch{if imageGeneration==epoch{note("截图 OCR 失败："+error.localizedDescription)}}
    }
    func setRegion(_ region: Region) {
        guard !running,region.valid else{return}
        if offline {offlineList=region;note("截图列表区域已调整；点击“验证选区”重新识别。实时监控配置保持原值。");return}
        if regionMode==1 {settings.list=region} else if regionMode==2 {settings.body=region} else{return}
        do{try save();note("区域已保存。启动前请核对：蓝色为列表，绿色为正文。")}catch{note(error.localizedDescription)}
    }
    func verifyOfflineRegion() async {
        guard offline,!busy,let image=preview,let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil),let crop=cg.cropping(to:offlineList.rect(CGSize(width:cg.width,height:cg.height)).integral) else{return}
        busy=true;defer{busy=false}
        do {
            let result=try await Task.detached{(try recognize(crop),UnreadList.dots(crop))}.value
            let rows=UnreadList.rows(result.0,dots:result.1,now:Date())
            ocrSummary="选区 \(result.0.count) 行，完整邮件 \(rows.count) 封，其中未读 \(rows.filter(\.unread).count) 封。"
            offlineDetails=rows.map{($0.unread ? "未读 · ":"已读 · ")+$0.subject}.joined(separator:"  |  ")
            note("截图选区验证完成："+ocrSummary)
        }catch{note("截图选区识别失败")}
    }
    func approveMailbox(_ window:SCWindow)->Bool {
        guard let page=PublicMailbox.inspect(window) else {
            note("无法核对邮箱页面。请在 Safari 打开 HTTPS 远程 Foxmail，选中邮箱标签，并确认辅助功能已开启。")
            return false
        }
        if settings.approvedPage==page.digest{return true}
        let dialog=NSAlert()
        dialog.messageText="允许监控这个邮箱页面？"
        dialog.informativeText=page.host+"\n"+(window.title ?? "")+"\n\n程序会读取这个页面的未读邮件，并按你的通知设置发送。页面地址变化后需要重新确认。"
        dialog.addButton(withTitle:"允许监控");dialog.addButton(withTitle:"取消")
        dialog.buttons[0].keyEquivalent="";dialog.buttons[1].keyEquivalent="\r"
        guard dialog.runModal() == .alertFirstButtonReturn,PublicMailbox.inspect(window)?.digest==page.digest else{return false}
        settings.approvedPage=page.digest
        return true
    }
    func start() {
        guard !running,!busy,!testInFlight,!offline,startupError==nil,selection != 0,let window=windows.first(where:{$0.windowID==selection}) else{return}
        permissions()
        guard screenAllowed else{requestScreen();return}
        if (settings.autoOpen || !SystemPortal.isAdapted) && !accessibility {requestAccessibility();return}
        guard SystemPortal.isAdapted || approveMailbox(window) else{return}
        do {
            settings.title=window.title ?? "";settings.bundle=window.owningApplication?.bundleIdentifier ?? ""
            try save()
            // Keep queues independent across selected targets, not ephemeral window IDs.
            let identity=Rules.hash(settings.bundle+"/"+settings.title)
            let url=Storage.root.appendingPathComponent("inbox-\(identity).json")
            if FileManager.default.fileExists(atPath:url.path) {inbox=try JSONDecoder().decode(InboxLedger.self,from:Data(contentsOf:url));guard inbox.version==2 else{throw failure("邮件队列版本无法读取")}}
            else {
                inbox=InboxLedger()
                let legacy=Storage.root.appendingPathComponent("state-\(identity).json")
                if FileManager.default.fileExists(atPath:legacy.path) {
                    let previous=try JSONDecoder().decode(Ledger.self,from:Data(contentsOf:legacy))
                    inbox.legacySent=Set(previous.records.filter{["Sending","Accepted","Uncertain"].contains($0.value)}.map(\.key))
                }
            }
            inbox.recover();ledgerURL=url;try persistInbox()
            readingMail=nil;listSignature="";stableListFrames=0;firstInboxSnapshot=true;pageBeforeScroll=nil;pagerFrames=0;listAtTop=true;lastPageTurn = .distantPast
            frameRect=nil;lastFrameAt=nil;transportPaused=inbox.tickets.contains{$0.state == .rejected}
            listOCRCache=FrameOCRCache();bodyOCRCache=FrameOCRCache();lastLayoutCheck = .distantPast
            running=true;generation+=1;let epoch=generation
            recovery.cancel();reconnecting=false;recoveryPortalOpened=false;automaticLoginSubmitted=false;missingMailboxFrames=0
            note(hasToken ? "逐封监控已启动。先检查推送配置并保存未读队列；配置可用且输入空闲后才自动打开邮件。":"观察模式已启动；未读邮件只排队，不自动打开，配置微信后再处理。")
            if hasToken{loadNotificationSecret()}
            if SystemPortal.isAdapted && hasSystemCredentials && settings.autoOpen{loadPortalSecret()}
            watchNotificationHealth()
            task=Task {
                while !Task.isCancelled && self.running && self.generation==epoch {
                    await self.scanInbox(epoch:epoch)
                    try? await Task.sleep(nanoseconds:1_000_000_000)
                }
            }
        } catch { note("启动失败："+error.localizedDescription) }
    }
    func stop() {
        running=false;generation+=1;task?.cancel();task=nil;readingMail=nil
        notificationHealthTask?.cancel();notificationHealthTask=nil;updateNotificationHealth()
        recovery.cancel();recoveryTask?.cancel();recoveryTask=nil
        if recoveryProcess?.isRunning == true{recoveryProcess?.terminate()};recoveryProcess=nil
        portalReadGate.invalidate();reconnecting=false
        note("监控已停止。已提交给服务的通知不能撤回。")
    }
    func persistInbox()throws {
        guard let url=ledgerURL else{throw failure("邮件队列未就绪")}
        try Storage.write(inbox,to:url);queuedCount=inbox.waiting;uncertainCount=inbox.uncertain
    }
    func active(_ w: SCWindow,at point:CGPoint?=nil)->Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier==w.owningApplication?.processID else{return false}
        if !SystemPortal.isAdapted {
            guard w.windowID==selection,let approved=settings.approvedPage,
                  let page=PublicMailbox.inspect(w),page.digest==approved else{return false}
            return point.map(page.viewport.contains) ?? true
        }
        guard SafariDevice.state() == .remote,let focused=SafariDevice.window(),let rect=SafariDevice.rect(focused),
              SafariDevice.text(focused)==w.title else{return false}
        return abs(rect.minX-w.frame.minX)<3 && abs(rect.minY-w.frame.minY)<3 &&
            abs(rect.width-w.frame.width)<3 && abs(rect.height-w.frame.height)<3
    }
    func tell(_ message:String) {if status != message{note(message)}}
    func clickPoint(_ point:CGPoint,window:SCWindow) async ->Bool {
        let epoch=generation
        guard running,notificationAvailability.canOpenMail,AXIsProcessTrusted(),active(window),CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:CGEventType(rawValue:UInt32.max)!)>2 else{return false}
        let flags=CGEventSource.flagsState(.combinedSessionState)
        guard flags.intersection([.maskShift,.maskControl,.maskAlternate,.maskCommand]).isEmpty,
              !CGEventSource.buttonState(.combinedSessionState,button:.left),!CGEventSource.buttonState(.combinedSessionState,button:.right) else{return false}
        guard point.x>2,point.y>2,point.x<window.frame.width-2,point.y<window.frame.height-2 else{return false}
        let p=CGPoint(x:window.frame.minX+point.x,y:window.frame.minY+point.y)
        guard active(window,at:p) else{return false}
        let system=AXUIElementCreateSystemWide();var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system,Float(p.x),Float(p.y),&element) == .success,let element else{return false}
        var pid: pid_t=0;guard AXUIElementGetPid(element,&pid) == .success,pid==window.owningApplication?.processID else{return false}
        guard let move=CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:p,mouseButton:.left),
              let down=CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:p,mouseButton:.left),
              let up=CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:p,mouseButton:.left) else{return false}
        // Guacamole stores its remote pointer on mousemove; a down event alone
        // clicks the previous remote position even if its macOS location differs.
        move.flags=[];move.post(tap:.cghidEventTap)
        try? await Task.sleep(nanoseconds:150_000_000)
        guard running,generation==epoch,notificationAvailability.canOpenMail,active(window,at:p),!CGEventSource.buttonState(.combinedSessionState,button:.left) else{return false}
        down.flags=[];up.flags=[]
        down.setIntegerValueField(.mouseEventClickState,value:1);up.setIntegerValueField(.mouseEventClickState,value:1)
        down.post(tap:.cghidEventTap)
        try? await Task.sleep(nanoseconds:80_000_000)
        up.post(tap:.cghidEventTap);return true
    }

}

struct CapturePreview: View {
    @ObservedObject var model: Monitor
    var body: some View {
        GeometryReader { proxy in
            if let image=model.preview {
                let ratio=min(proxy.size.width/image.size.width,proxy.size.height/image.size.height)
                let size=CGSize(width:image.size.width*ratio,height:image.size.height*ratio)
                ZStack(alignment:.topLeading) {
                    Image(nsImage:image).resizable().frame(width:size.width,height:size.height)
                    box(model.previewList.rect(size),.blue,"邮件列表")
                    if !model.offline{box(model.settings.body.rect(size),.green,"邮件正文")}
                    if let drag=model.drag{Rectangle().stroke(.orange,lineWidth:2).frame(width:drag.width,height:drag.height).offset(x:drag.minX,y:drag.minY)}
                }.frame(width:size.width,height:size.height).clipped().contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:4).onChanged { value in
                    guard model.regionMode != 0,!model.running else{return}
                    let x1=max(0,min(size.width,value.startLocation.x)),x2=max(0,min(size.width,value.location.x))
                    let y1=max(0,min(size.height,value.startLocation.y)),y2=max(0,min(size.height,value.location.y))
                    model.drag=CGRect(x:min(x1,x2),y:min(y1,y2),width:abs(x2-x1),height:abs(y2-y1))
                }.onEnded{_ in if let r=model.drag{model.setRegion(Region(x:r.minX/size.width,y:r.minY/size.height,w:r.width/size.width,h:r.height/size.height))};model.drag=nil})
                .frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ContentUnavailableView("预览所选邮箱窗口",systemImage:"viewfinder",description:Text("选择窗口后点击“预览识别”，再拖选邮件列表与正文区域。"))
            }
        }
    }
    func box(_ r:CGRect,_ color:Color,_ text:String)->some View {
        Rectangle().stroke(color,lineWidth:2).background(color.opacity(0.06)).overlay(alignment:.topLeading){Text(text).font(.caption).padding(3).background(color).foregroundStyle(.white)}.frame(width:r.width,height:r.height).offset(x:r.minX,y:r.minY).allowsHitTesting(false)
    }
}
@main struct MailMonitorApp: App {
    @StateObject var model:Monitor
    init() {
        if CommandLine.arguments.contains("--self-test") {do{try SelfTests.run();exit(0)}catch{print("FAIL: \(error.localizedDescription)");exit(1)}}
        if let index=CommandLine.arguments.firstIndex(of:"--replay"),index+1<CommandLine.arguments.count {
            do{try SelfTests.replay(URL(fileURLWithPath:CommandLine.arguments[index+1]));exit(0)}catch{print("FAIL: \(error.localizedDescription)");exit(1)}
        }
        _model=StateObject(wrappedValue:Monitor())
    }
    var body:some Scene {Window("抽查邮件监控",id:"main"){MainView(m:model)}.defaultSize(width:1160,height:820).commands{CommandGroup(replacing:.newItem){}}}
}

enum SelfTests {
    static func replay(_ url:URL) throws {
        guard let image=NSImage(contentsOf:url),let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else{throw failure("image unreadable")}
        let lines=try recognize(cg)
        let events=lines.flatMap{Rules.titles($0.text)}
        let date=events.map(\.day).max().flatMap{Rules.dateFormat("yyyy-MM-dd").date(from:$0)} ?? Date()
        let rows=Rules.rows(lines,now:date)
        let unread=UnreadList.rows(lines,dots:UnreadList.dots(cg),now:date)
        var report:[String:Any] = ["image":url.lastPathComponent,"width":cg.width,"height":cg.height,"ocr_lines":lines.count,"sender_matches":lines.filter{Rules.sender($0.text)}.count,"events":events.map{["kind":$0.kind,"day":$0.day,"batch":String($0.batch)]},"verified_row_kinds":rows.map{$0.event.kind},"complete_mail_rows":unread.count,"unread_rows":unread.filter(\.unread).count,"mode":"offline-no-click-no-send"]
        let size=CGSize(width:cg.width,height:cg.height)
        if let layout=MailboxLayout.regions(lines,size:size,list:Settings().list,body:Settings().body),
           let listImage=cg.cropping(to:layout.0.rect(size).integral),let bodyImage=cg.cropping(to:layout.1.rect(size).integral) {
            let local=UnreadList.rows(try recognize(listImage),dots:UnreadList.dots(listImage),now:date)
            let bodyLines=try recognize(bodyImage)
            report["layout_list"]=layout.0.rect(size).debugDescription;report["layout_body"]=layout.1.rect(size).debugDescription
            report["layout_unread_rows"]=local.filter(\.unread).count
            report["body_business_titles"]=bodyLines.flatMap{Rules.titles($0.text)}.map(\.id)
            report["body_other_list_subjects"]=bodyLines.filter{$0.text.contains("Cacti-All设备上线") || $0.text.contains("客服电话检查")}.count
        }
        let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);print(String(data:data,encoding:.utf8)!)
    }
    static func run() throws {
        var checks=0
        func check(_ condition:Bool,_ name:String)throws{guard condition else{throw failure(name)};checks+=1}
        try check(SystemPortal.url.scheme=="https" && SystemPortal.url.host=="portal.example.com" && SystemPortal.url.port==9978,"fixed system origin")
        try check(SystemPortal.url.path=="/admin.php" && SystemPortal.url.query=="controller=admin_index&action=login" && SystemPortal.url.user==nil && SystemPortal.url.password==nil,"fixed login route without credentials")
        try check(SystemPortal.browserID=="com.apple.Safari","explicit Safari browser")
        let samplePage=URL(string:"https://relay.example.org/remote/#/client/demo")!
        let digest=PublicMailbox.identity(samplePage,title:"Foxmail")
        try check(digest?.count==64,"public page stored only as digest")
        try check(PublicMailbox.identity(samplePage,title:"other") != digest,"public pin requires exact window title")
        for value in ["http://relay.example.org/remote/#/client/demo","https://user@relay.example.org/remote/#/client/demo","file:///remote"] {
            try check(PublicMailbox.identity(URL(string:value)!,title:"Foxmail")==nil,"forbidden public page URL")
        }
        for value in ["https://elsewhere.example.org/remote/#/client/demo","https://relay.example.org/other/#/client/demo","https://relay.example.org/remote/#/client/other","https://relay.example.org:9999/remote/#/client/demo"] {
            try check(PublicMailbox.identity(URL(string:value)!,title:"Foxmail") != digest,"public origin and page are pinned")
        }
        let fallbackSettings=try JSONDecoder().decode(Settings.self,from:Data("{}".utf8))
        try check(fallbackSettings.approvedPage == nil,"legacy settings require explicit page approval")
        let visibleSubject="数据异常：DEMO-CDR1-198.51.100.21",visibleID="0123456789abcdef0123456789abcdef"
        let noticeA=NotificationText.title(visibleSubject,sentAt:"2026-10-14 07:01:00",alarm:true,eventID:visibleID)
        let noticeB=NotificationText.title(visibleSubject,sentAt:"2026-10-14 06:11:00",alarm:true,eventID:visibleID)
        try check(noticeA.hasPrefix("10-14 07:01｜"+visibleSubject),"verified mail time and original subject precede alarm metadata")
        try check(String(noticeA.prefix(20)) != String(noticeB.prefix(20)),"short WeChat previews distinguish identical subjects by mail time")
        try check(noticeA.hasSuffix("【夜间告警】[事件:0123456789abcdef]"),"existing Android event and marker syntax remain complete at title end")
        try check(NotificationText.title(visibleSubject,sentAt:"2026-10-14 07:01:00",alarm:false,eventID:visibleID)=="10-14 07:01｜"+visibleSubject,"ordinary mail title has no technical prefix or suffix")
        let longNotice=NotificationText.title(String(repeating:"很长的邮件主题",count:30),sentAt:"2026-10-14 07:01:00",alarm:true,eventID:visibleID)
        try check(longNotice.count==100 && longNotice.contains("…") && longNotice.hasSuffix("[事件:0123456789abcdef]"),"long subject cannot truncate time or Android alarm identity")
        try check(NotificationText.title(visibleSubject,sentAt:"invalid",alarm:false,eventID:visibleID)==visibleSubject,"missing verified mail date never invents current arrival time")
        try check(NotificationText.title("普通\n工作邮件",alarm:false,eventID:visibleID)=="普通 工作邮件","mail headings cannot inject title line breaks")
        try check(NotificationText.title(visibleSubject,sentAt:"2026-10-14 07:01:00",alarm:true,eventID:visibleID)==noticeA,"same mail keeps the same phone event identity")
        var secretGate=SecretReadGate();let secretStart=Date(timeIntervalSince1970:100)
        guard let secretRequest=secretGate.begin(now:secretStart) else{throw failure("secret probe starts")}
        try check(secretGate.begin(now:secretStart.addingTimeInterval(1)) == nil,"one outstanding keychain probe prevents repeated requests")
        try check(!secretGate.expire(secretRequest,now:secretStart.addingTimeInterval(4.9)),"a short keychain probe remains usable")
        try check(secretGate.expire(secretRequest,now:secretStart.addingTimeInterval(5)),"a stuck keychain probe stops waiting after five seconds")
        try check(!secretGate.finish(secretRequest),"late keychain results cannot replace explicit authorization")
        guard let newSecretRequest=secretGate.begin(now:secretStart.addingTimeInterval(6)) else{throw failure("new explicit probe")}
        try check(!secretGate.expire(secretRequest,now:secretStart.addingTimeInterval(12)),"old watchdog cannot expire a newer request")
        try check(secretGate.finish(newSecretRequest),"successful current keychain probe completes")
        let replacedSecretRequest=secretGate.begin(now:secretStart.addingTimeInterval(20))!
        secretGate.invalidate()
        try check(!secretGate.finish(replacedSecretRequest),"replacing token discards a prior probe result")
        let remote="https://portal.example.com:9978/baoleiji/#/client/test"
        try check(SafariDevice.resolvedURL(String(remote.dropFirst(8)),address:remote)?.absoluteString==remote,"scheme-less Safari web area is confirmed by full address")
        try check(SafariDevice.resolvedURL(String(remote.dropFirst(8)),address:remote+"other")==nil,"edited address cannot authenticate a different web area")
        try check(SafariDevice.resolvedURL(String(remote.dropFirst(8)),address:nil)==nil,"never guess HTTPS from a scheme-less URL")
        try check(SafariDevice.resolvedURL(String(remote.dropFirst(8)),address:remote.replacingOccurrences(of:"https:",with:"http:"))==nil,"no HTTP fallback upgrade")
        try check(SafariDevice.resolvedURL(remote,address:nil)?.scheme=="https","normal full HTTPS AX URL")
        let remoteURL=URL(string:remote)!,remoteTitle="administrator@192.0.2.11"
        try check(SafariDevice.isRemoteURL(remoteURL,title:remoteTitle),"real remote route survives Foundation trailing slash normalization")
        try check(!SafariDevice.isRemoteURL(URL(string:remote.replacingOccurrences(of:"/baoleiji/",with:"/baoleiji"))!,title:remoteTitle),"remote route requires the exact directory URL")
        try check(!SafariDevice.isRemoteURL(URL(string:remote.replacingOccurrences(of:"/baoleiji/",with:"/baoleiji-other/"))!,title:remoteTitle),"sibling page cannot be classified as remote")
        try check(!SafariDevice.isRemoteURL(URL(string:remote.replacingOccurrences(of:"portal.example.com",with:"example.com"))!,title:remoteTitle),"remote route requires the authorized host")
        try check(!SafariDevice.isRemoteURL(URL(string:remote.replacingOccurrences(of:"https:",with:"http:"))!,title:remoteTitle),"remote route requires HTTPS")
        try check(!SafariDevice.isRemoteURL(remoteURL,title:"unrelated page"),"remote route requires the selected device title")
        try check(!PortalCredentials(username:" ",password:"test").valid && !PortalCredentials(username:"test",password:"").valid,"reject empty portal credentials")
        try check(SafariLogin.quote("a\"b\\c\nd")=="\"a\\\"b\\\\c\\nd\"","AppleScript escaping")
        let sample=PortalCredentials(username:"synthetic-user",password:"synthetic-only-\"\\\n")
        let source=try SafariLogin.script(sample)
        var compileError:NSDictionary?
        try check(NSAppleScript(source:source)?.compileAndReturnError(&compileError)==true,"Safari login AppleScript compiles with escaped synthetic data")
        let now=Rules.dateFormat("yyyy-MM-dd HH:mm").date(from:"2026-09-28 21:00")!
        func body(_ code:String="063827",_ batch:Int=9)->String {"告警抽查邮件2026年09月28日\(batch)次\nreport@example.com\n2026-09-28 21:00\n确认码：\(code)\n请在15分钟内完成"}
        let event=MailEvent(kind:"alert",day:"2026-09-28",batch:9)
        try check(Rules.titles(body()).first==event,"parse title")
        try check(Rules.code(body(),expected:event,now:now)=="063827","leading zero")
        try check(Rules.code(body("０６３８２７"),expected:event,now:now)=="063827","full width")
        try check(Rules.code(body("063 827"),expected:event,now:now)=="063827","grouped digits")
        for value in ["8943","12345","1234567","A12345","063827 或 582914","063827 582914","063827.9","063827@x.com"]{try check(Rules.code(body(value),expected:event,now:now)==nil,"reject ambiguous code")}
        try check(Rules.code(body("063827",8),expected:event,now:now)==nil,"reject old preview")
        try check(Rules.code(body().replacingOccurrences(of:"report@",with:"xreport@"),expected:event,now:now)==nil,"reject wrong sender")
        try check(Rules.code(body().replacingOccurrences(of:".com",with:".com.other"),expected:event,now:now)==nil,"reject sender suffix")
        try check(Rules.code(body(),expected:event,now:now.addingTimeInterval(900))==nil,"expiry")
        try check(Rules.code(body(),expected:event,now:now.addingTimeInterval(-180))==nil,"future")
        try check(Rules.code(body().replacingOccurrences(of:"2026-09-28 21:00",with:""),expected:event,now:now)==nil,"require time")
        let phone=MailEvent(kind:"phone",day:event.day,batch:9)
        let phoneBody=body("0843").replacingOccurrences(of:"告警抽查邮件",with:"客服电话检查").replacingOccurrences(of:"确认码",with:"验证码")
        try check(Rules.code(phoneBody,expected:phone,now:now)=="0843","phone four digits")
        var ledger=Ledger()
        try check(!ledger.consider(MailEvent(kind:"alert",day:"2026-09-27",batch:99),now:now),"baseline old day")
        try check(ledger.consider(event,now:now),"new day lower batch")
        ledger.record(event,"Sending")
        var restored=try JSONDecoder().decode(Ledger.self,from:JSONEncoder().encode(ledger))
        try check(!restored.consider(event,now:now),"uncertain send not replayed")
        try check(!restored.consider(phone,now:now),"phone independent baseline")
        let lines=[OCRLine(text:"report@example.com",rect:CGRect(x:20,y:60,width:250,height:14)),OCRLine(text:"告警抽查邮件2026年09月28日9次",rect:CGRect(x:20,y:80,width:260,height:14))]
        try check(Rules.rows(lines,now:now).count==1,"adjacent sender")
        try check(Rules.rows(lines+lines,now:now).isEmpty,"duplicate rows")
        try check(!Region(x:0.9,y:0,w:0.3,h:1).valid,"region bounds")
        // Real Vision OCR on a locally rendered synthetic Chinese mail, no screen permission needed.
        let image=NSImage(size:NSSize(width:1400,height:460))
        image.lockFocus();NSColor.white.setFill();NSBezierPath(rect:CGRect(x:0,y:0,width:1400,height:460)).fill()
        let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:32),.foregroundColor:NSColor.black]
        for (i,line) in body().components(separatedBy:"\n").enumerated(){(line as NSString).draw(at:NSPoint(x:30,y:380-i*65),withAttributes:attributes)}
        image.unlockFocus()
        guard let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil)else{throw failure("synthetic image")}
        let ocr=try recognize(cg).map(\.text).joined(separator:"\n")
        try check(Rules.code(ocr,expected:event,now:now)=="063827","real Chinese Vision OCR -> business parser")
        for credentials in [nil,sample] as [PortalCredentials?] {
            let recoverySource=try SafariLogin.recoveryScript(credentials)
            var error:NSDictionary?
            try check(NSAppleScript(source:recoverySource)?.compileAndReturnError(&error)==true,"one-shot recovery AppleScript compiles")
            try check(!recoverySource.contains("activate") && !recoverySource.contains("repeat"),"recovery script has no autonomous activation or retry loop")
        }
        let mailboxLabels=["Foxmail","收件箱 (0)","排序：是否已读"].map{OCRLine(text:$0,rect:CGRect(x:20,y:20,width:150,height:20))}
        for argument in ["false","\"focus\""] {
            var error:NSDictionary?
            try check(NSAppleScript(source:try SafariLogin.pageScript(resource:"portal-device",argument:argument))?.compileAndReturnError(&error)==true,"device probe and focus AppleScript compile without credentials")
        }
        try check(Monitor.isMailboxFrame(mailboxLabels),"connected empty inbox is healthy without mail rows")
        try check(!Monitor.isMailboxFrame([]),"blank retained remote route cannot confirm connection")
        try check(!Monitor.isMailboxFrame([OCRLine(text:"已断开连接",rect:.zero)]),"disconnected screen cannot confirm mailbox")
        try check(!Monitor.isMailboxFrame([OCRLine(text:"Foxmail",rect:.zero)]),"desktop shortcut alone cannot confirm inbox")
        let toolbarLabels=["收取","回复","转发","收件箱 (2)","排序：日期"].map{OCRLine(text:$0,rect:.zero)}
        try check(Monitor.isMailboxFrame(toolbarLabels),"mail toolbar verifies inbox when logo OCR is unavailable")
        try check(!Monitor.isMailboxFrame(Array(toolbarLabels.dropLast())),"toolbar and inbox without sorting cannot verify mailbox")
        try check(!Monitor.isMailboxFrame(Array(toolbarLabels.dropFirst())),"partial toolbar without logo cannot verify mailbox")
        try check(Monitor.isMailboxFrame(["Foxmail","收取一","回复、","转发一","排序：日期"].map{OCRLine(text:$0,rect:.zero)}),"complete toolbar and logo tolerate missing folder OCR")
        // Exact labels returned by the live preview on 2026-10-30. Vision lost
        // both the selected folder label and one toolbar item on a healthy page.
        let liveMailbox=["Foxmail","收取一","回复全部一","排序是杏已读^"]
        try check(Monitor.isMailboxFrame(liveMailbox.map{OCRLine(text:$0,rect:.zero)}),"live mailbox with one missing toolbar item does not trigger a reconnect")
        try check(!Monitor.isMailboxFrame(["Foxmail","回复全部一","排序是杏已读^"].map{OCRLine(text:$0,rect:.zero)}),"one toolbar group cannot confirm a mailbox without its folder label")
        try check(!Monitor.isMailboxFrame(["收取一","回复全部一","排序是杏已读^"].map{OCRLine(text:$0,rect:.zero)}),"partial toolbar without a mail brand or folder remains unverified")
        try check(!Monitor.isMailboxFrame(["Foxmail","收取一","回复全部一"].map{OCRLine(text:$0,rect:.zero)}),"a missing list sort label remains unverified")
        try check(Monitor.isMailboxFrame((liveMailbox+["告警说明：设备已断开连接"]).map{OCRLine(text:$0,rect:.zero)}),"a disconnected device mentioned in mail is not a browser disconnect")
        let recoveryChecks=try RecoveryPolicyTests.run()
        print("PASS \(recoveryChecks) reconnect policy checks; no UI or secrets.")
        let notificationChecks=try NotificationHealthTests.run()
        print("PASS \(notificationChecks) notification health checks; no UI, secrets or sends.")
        _ = try InboxTests.run()
        print("PASS \(checks) checks; real Vision Chinese OCR passed; no network sends or clicks.")
    }
}
