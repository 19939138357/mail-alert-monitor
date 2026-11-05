import Foundation
import AppKit
import ScreenCaptureKit
import ApplicationServices

@MainActor extension Monitor {
    func recoveryValid(_ id:UUID,_ epoch:Int)->Bool {
        running && generation==epoch && recovery.inFlight==id && !Task.isCancelled
    }
    func resetMailboxPages() throws {
        // Only the in-memory page sequence is invalid after a new connection.
        // The original opened identity, complete bodies and delivery facts stay.
        if let reading=readingMail {
            inbox.set(reading.ticketID,.queued);try persistInbox()
        }
        readingMail=nil;stableListFrames=0;listSignature="";pageBeforeScroll=nil;pagerFrames=0
        frameRect=nil;lastFrameAt=nil;listAtTop=true
        lastRemoteHealthCheck = .distantPast
        listOCRCache=FrameOCRCache();bodyOCRCache=FrameOCRCache();lastLayoutCheck = .distantPast
    }
    func prepareMailbox(epoch:Int) async throws ->Bool {
        guard running,generation==epoch else{return false}
        guard settings.autoOpen,settings.bundle==SystemPortal.browserID,settings.title=="administrator@192.0.2.11" else{return true}
        if SafariDevice.state() == .remote,!SafariDevice.interrupted(),!reconnecting{return true}
        if !reconnecting {
            try resetMailboxPages();reconnecting=true;mailReady=false
            note("远程连接中断或页面已离开，正在自动恢复监控机 1；待处理邮件已保存。")
        }
        guard recovery.inFlight==nil,Date()>=recovery.nextAttempt else{return false}
        guard SafariDevice.inputIdle() else{tell("等待鼠标键盘空闲后自动重连；完整正文和待处理邮件已保留。");return false}
        guard let id=recovery.begin(now:Date()) else{return false}
        note("正在自动重连监控机 1（第 \(recovery.attempts+1) 次）。")
        recoveryTask=Task {await self.recoverMailbox(id:id,epoch:epoch)}
        return false
    }
    func recoverMailbox(id:UUID,epoch:Int) async {
        var verifiedFrames=0,clickedEntry=false,triedReconnect=false,restoredTabs=false,reloadedPortal=false,refreshedLogin=false
        recoveryPortalOpened=false // Each attempt first reuses the live/cached tab.
        let deadline=Date().addingTimeInterval(50)
        defer {
            if recovery.inFlight==id {
                _=recovery.finish(id,recovered:false,now:Date())
                if running,generation==epoch {
                    let delay=max(1,Int(recovery.nextAttempt.timeIntervalSinceNow.rounded(.up)))
                    note(portalNeedsUnlock ? "自动重连等待系统账号授权；点“授权连接”后继续，待处理邮件保留。":"本次连接尚未恢复，\(delay) 秒后自动再试；待处理邮件保留。")
                }
            }
        }
        do {
            guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:SystemPortal.browserID) else{throw failure("未找到 Safari")}
            guard recoveryValid(id,epoch),SafariDevice.inputIdle() else{return}
            let configuration=NSWorkspace.OpenConfiguration();configuration.activates=true
            _=try await NSWorkspace.shared.openApplication(at:url,configuration:configuration)
            while recoveryValid(id,epoch),Date()<deadline {
                try await Task.sleep(nanoseconds:1_000_000_000)
                guard recoveryValid(id,epoch) else{return}
                // No automatic input while the user or a system authentication
                // window owns the keyboard. Waiting does not open more tabs.
                guard SafariDevice.inputIdle() else{continue}
                let state=SafariDevice.state()
                if state == .login,!restoredTabs {
                    restoredTabs=true
                    if SafariDevice.restoreDeviceTab(){continue}
                }
                if state == .remote {
                    if SafariDevice.interrupted() {
                        verifiedFrames=0
                        if !triedReconnect {
                            triedReconnect=true
                            if SafariDevice.pressReconnect(){note("已点击原远程会话的重新连接，等待邮箱画面恢复。");continue}
                        }
                        if !clickedEntry,try await restoreRecoveryPortal(id:id,epoch:epoch,url:url,configuration:configuration){continue}
                    } else if let window=try await verifiedMailboxWindow(id:id,epoch:epoch) {
                        guard recoveryValid(id,epoch) else{return}
                        verifiedFrames+=1
                        if verifiedFrames>=2 {
                            selection=window.windowID;windows=[window]+windows.filter{$0.windowID != window.windowID}
                            try resetMailboxPages();mailReady=true;missingMailboxFrames=0
                            _=recovery.finish(id,recovered:true,now:Date());reconnecting=false
                            recoveryPortalOpened=false;automaticLoginSubmitted=false
                            note("监控机 1 已自动重连，邮箱画面连续核对通过，继续原来的未读任务。")
                            return
                        }
                    } else {
                        verifiedFrames=0
                        // A retained URL/title is not proof of a live desktop.
                        // Try the original device entry after the display has
                        // had time to connect, without closing remote programs.
                        if Date().timeIntervalSince(deadline.addingTimeInterval(-50))>15,!clickedEntry,
                           try await restoreRecoveryPortal(id:id,epoch:epoch,url:url,configuration:configuration){continue}
                    }
                } else if state == .devices {
                    SafariDevice.rememberPortal()
                    verifiedFrames=0
                    if !clickedEntry {
                        try await enterDevice(valid:{self.recoveryValid(id,epoch)})
                        guard recoveryValid(id,epoch) else{return}
                        clickedEntry=true;note("已从监控机 1 左侧浏览器入口重新连接，等待实际邮箱画面。")
                    }
                } else if state == .login {
                    SafariDevice.rememberPortal()
                    verifiedFrames=0
                    if !automaticLoginSubmitted,!refreshedLogin {
                        refreshedLogin=true
                        if SafariDevice.reloadPortal(){continue}
                    }
                    let probe=await recoveryLogin(nil,id:id,epoch:epoch)
                    guard recoveryValid(id,epoch) else{return}
                    if probe=="READY",!automaticLoginSubmitted {
                        guard let secret=portalSecret else{loadPortalSecret();continue}
                        guard SafariDevice.inputIdle(),SafariDevice.state() == .login else{continue}
                        automaticLoginSubmitted=true // Persist in this run before the side effect.
                        let result=await recoveryLogin(secret,id:id,epoch:epoch)
                        guard recoveryValid(id,epoch) else{return}
                        if result=="SUBMITTED"{clickedEntry=false;note("系统会话已过期，已提交一次保存的账号登录，等待结果。")}
                        else{note(SafariLogin.message(result));return}
                    } else if probe=="MANUAL" {
                        note("系统要求动态验证，请在 Safari 完成；完成后会自动继续连接。");return
                    } else if automaticLoginSubmitted,probe=="READY" {
                        // A rejected or uncertain login is never blindly replayed.
                        tell("系统登录尚未通过，请检查 Safari；完成登录后会自动继续连接。")
                    } else if probe != "WAIT",probe != "READY",probe != "SIGNED_IN" {
                        note(SafariLogin.message(probe));return
                    }
                } else {
                    verifiedFrames=0
                    if !restoredTabs,!clickedEntry {
                        restoredTabs=true
                        if SafariDevice.restoreRemoteTab() || SafariDevice.restorePortalTab(){continue}
                    }
                    if SafariDevice.isCurrentPortalAddress() {
                        SafariDevice.rememberPortal()
                        if !reloadedPortal{reloadedPortal=SafariDevice.reloadPortal()}
                    } else if !clickedEntry {
                        _=try await restoreRecoveryPortal(id:id,epoch:epoch,url:url,configuration:configuration)
                    }
                }
            }
        } catch {
            if recoveryValid(id,epoch){note("自动重连暂未完成："+error.localizedDescription)}
        }
    }
    func restoreRecoveryPortal(id:UUID,epoch:Int,url:URL,configuration:NSWorkspace.OpenConfiguration) async throws ->Bool {
        guard recoveryValid(id,epoch),SafariDevice.inputIdle() else{return false}
        if SafariDevice.restorePortalTab(){return true}
        guard !recoveryPortalOpened else{return false}
        recoveryPortalOpened=true
        do {
            _=try await NSWorkspace.shared.open([SystemPortal.url],withApplicationAt:url,configuration:configuration)
            guard recoveryValid(id,epoch) else{return false}
            SafariDevice.rememberPortal();return true
        } catch {recoveryPortalOpened=false;throw error}
    }
    func verifiedMailboxWindow(id:UUID,epoch:Int) async throws ->SCWindow? {
        let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
        guard recoveryValid(id,epoch) else{return nil}
        let matches=content.windows.filter{$0.owningApplication?.bundleIdentifier==SystemPortal.browserID && $0.title==settings.title && $0.frame.width>250 && $0.frame.height>180}
        guard matches.count==1,let window=matches.first else{return nil}
        let image=try await capture(window)
        let lines=try await Task.detached{try recognize(image)}.value
        guard recoveryValid(id,epoch),SafariDevice.state() == .remote,!SafariDevice.interrupted(),Self.isMailboxFrame(lines) else{return nil}
        if let layout=MailboxLayout.regions(lines,size:CGSize(width:image.width,height:image.height),list:settings.list,body:settings.body) {
            settings.list=layout.0;settings.body=layout.1;try save()
        }
        preview=NSImage(cgImage:image,size:window.frame.size);linesCount=lines.count
        return window
    }
    nonisolated static func isMailboxFrame(_ lines:[OCRLine])->Bool {
        let values=lines.map{Rules.compact($0.text)}
        // Real disconnect overlays are checked by SafariDevice.interrupted().
        // OCR text can include a mail about a disconnected device; it must not
        // be mistaken for the browser's own connection state.
        let toolbarCount=["收取","回复","转发"].filter{label in values.contains{$0.contains(label)}}.count
        let brand=values.contains{$0.localizedCaseInsensitiveContains("Foxmail")},inbox=values.contains{$0.contains("收件箱")}
        // The live selected folder and one toolbar label can both be missed by
        // OCR. Keep independent evidence: sort + brand + two toolbar groups.
        // Without the brand, retain the complete toolbar and inbox requirement.
        return values.contains{$0.contains("排序")} && ((brand && inbox) || (brand && toolbarCount>=2) || (inbox && toolbarCount==3))
    }
    func observeMailboxFrame(_ lines:[OCRLine]) throws ->Bool {
        if Self.isMailboxFrame(lines){missingMailboxFrames=0;return true}
        missingMailboxFrames+=1
        guard missingMailboxFrames>=2 else{return true}
        try resetMailboxPages();reconnecting=true;mailReady=false
        tell("未能连续确认 Foxmail 画面，正在自动检查远程连接；原邮件任务已保留。")
        return false
    }
    func loadPortalSecret() {
        guard portalSecret==nil,!portalNeedsUnlock,let id=portalReadGate.begin(now:Date()) else{return}
        Task { [weak self] in
            let value=await Task.detached{try? PortalVault.read(interactive:false)}.value
            guard let self,self.portalReadGate.finish(id) else{return}
            self.portalSecret=value;self.portalNeedsUnlock=(value==nil)
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds:5_000_000_000)
            guard let self,self.portalReadGate.expire(id,now:Date()) else{return}
            self.portalNeedsUnlock=true
        }
    }
    func unlockPortal() async {
        guard !unlockingPortal else{return};unlockingPortal=true;defer{unlockingPortal=false}
        portalReadGate.invalidate()
        note("请在本机钥匙串窗口授权原系统账号；完成后自动继续连接。")
        let value=await Task.detached{try? PortalVault.read()}.value
        portalSecret=value;portalNeedsUnlock=(value==nil)
        if value != nil{automaticLoginSubmitted=false;note("系统账号授权可用，自动重连将继续。")}
    }
    func recoveryLogin(_ credentials:PortalCredentials?,id:UUID,epoch:Int) async ->String {
        guard recoveryValid(id,epoch),SafariDevice.inputIdle(),SafariDevice.state() == .login,
              let source=try? SafariLogin.recoveryScript(credentials) else{return "BLOCKED"}
        return await runPageAction(source,valid:{self.recoveryValid(id,epoch)})
    }
    func enterDevice(valid:()->Bool) async throws {
        guard valid(),SafariDevice.inputIdle(),SafariDevice.state() == .devices else{throw failure("等待系统设备列表与输入空闲。")}
        let probe=try SafariLogin.pageScript(resource:"portal-device",argument:"\"point\"")
        let first=await runPageAction(probe,valid:valid,pointResult:true)
        guard valid(),let target=SafariDevice.browserPoint(first) else{throw failure("监控机 1 浏览器图标位置未能核对（\(first.hasPrefix("{") ? SafariDevice.browserPointIssue:first)），保留等待。")}
        let move=CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:target.point,mouseButton:.left)
        move?.flags=[];move?.post(tap:.cghidEventTap)
        try await Task.sleep(nanoseconds:2_200_000_000)
        let second=await runPageAction(probe,valid:valid,pointResult:true)
        guard valid(),SafariDevice.inputIdle(),let fresh=SafariDevice.browserPoint(second),
              CFEqual(target.window,fresh.window),CFEqual(target.web,fresh.web),target.point==fresh.point,
              let cursor=CGEvent(source:nil)?.location,abs(cursor.x-fresh.point.x)<2,abs(cursor.y-fresh.point.y)<2,
              let down=CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:fresh.point,mouseButton:.left),
              let up=CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:fresh.point,mouseButton:.left) else{throw failure("窗口或输入状态改变，保留等待。")}
        down.flags=[];up.flags=[]
        down.setIntegerValueField(.mouseEventClickState,value:1)
        up.setIntegerValueField(.mouseEventClickState,value:1)
        down.post(tap:.cghidEventTap)
        // Preserve an ordinary click's down/up interval. Always release even
        // when stop cancels this task between the two events.
        try? await Task.sleep(nanoseconds:80_000_000)
        up.post(tap:.cghidEventTap)
    }
    func runPageAction(_ source:String,valid:()->Bool,pointResult:Bool=false) async ->String {
        guard valid(),SafariDevice.inputIdle(),NSWorkspace.shared.frontmostApplication?.bundleIdentifier==SystemPortal.browserID,
              let data=source.data(using:.utf8) else{return "BLOCKED"}
        let process=Process(),input=Pipe(),output=Pipe()
        process.executableURL=URL(fileURLWithPath:"/usr/bin/osascript");process.arguments=["-"]
        process.standardInput=input;process.standardOutput=output;process.standardError=FileHandle.nullDevice
        recoveryProcess=process
        defer {
            if process.isRunning{process.terminate()}
            if recoveryProcess===process{recoveryProcess=nil}
        }
        do {
            guard valid() else{return "TIMEOUT"}
            try process.run();try input.fileHandleForWriting.write(contentsOf:data);try input.fileHandleForWriting.close()
            let deadline=Date().addingTimeInterval(12)
            while process.isRunning,valid(),Date()<deadline{try await Task.sleep(nanoseconds:100_000_000)}
            guard valid(),!process.isRunning else{return "UNCERTAIN"}
            let result=String(data:output.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "FAILED"
            if pointResult,result.utf8.count<1024,let data=result.data(using:.utf8),
               (try? JSONDecoder().decode(SafariDevice.BrowserGeometry.self,from:data)) != nil{return result}
            return ["SIGNED_IN","SUBMITTED","READY","WAIT","BLOCKED","MANUAL","UNCERTAIN","TIMEOUT","ENTERED","FOCUSED"].contains(result) ? result:"AUTOMATION_REQUIRED"
        } catch {return "UNCERTAIN"}
    }
}
