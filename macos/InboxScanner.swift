import Foundation
import AppKit
import ScreenCaptureKit
import ApplicationServices

@MainActor extension Monitor {
    func scanInbox(epoch:Int) async {
        guard !busy else{return};busy=true;defer{busy=false}
        do {
            // Completed mail does not depend on the remote desktop being online.
            if notificationAvailability.canOpenMail,let ready=inbox.tickets.first(where:{$0.state == .ready && $0.content != nil}) {
                try await sendInbox(ready,epoch:epoch)
            }
            guard running,generation==epoch,try await prepareMailbox(epoch:epoch) else{return}
            let window=try await currentWindow()
            guard running,generation==epoch else{return}
            // ScreenCaptureKit can read the selected window independently of focus.
            // Focus is required only for input, never for discovering/queuing mail.
            if frameRect != window.frame {
                listOCRCache=FrameOCRCache();bodyOCRCache=FrameOCRCache();lastLayoutCheck = .distantPast
            }
            if frameRect != window.frame || (lastFrameAt.map{Date().timeIntervalSince($0)>8} ?? false) {stableListFrames=0;readingMail?.stableFrames=0}
            frameRect=window.frame
            let image=try await capture(window),size=CGSize(width:image.width,height:image.height)
            let savedList=settings.list,savedBody=settings.body
            // The mail header scrolls with the body. Do not let text revealed by
            // paging move the crop or discard the task that changed unread state.
            let checkLayout=readingMail == nil && Date().timeIntervalSince(lastLayoutCheck)>=15
            let checkHealth=(!SystemPortal.isAdapted || (settings.autoOpen && settings.bundle==SystemPortal.browserID && settings.title=="administrator@192.0.2.11")) && Date().timeIntervalSince(lastRemoteHealthCheck)>=15
            let fullLines=(checkLayout || checkHealth) ? try await Task.detached{try recognize(image)}.value:[]
            guard running,generation==epoch else{return}
            if checkHealth {
                if SystemPortal.isAdapted {
                    lastRemoteHealthCheck=Date()
                    guard try observeMailboxFrame(fullLines) else{return}
                } else {
                    guard Self.isMailboxFrame(fullLines) else {
                        mailReady=false;stableListFrames=0
                        tell("尚未识别到 Foxmail 收件箱，请检查选中的邮箱画面。")
                        return
                    }
                    mailReady=true;lastRemoteHealthCheck=Date()
                }
            }
            let detected=checkLayout ? MailboxLayout.regions(fullLines,size:size,list:savedList,body:savedBody):nil
            if checkLayout{lastLayoutCheck=Date()}
            guard running,generation==epoch else{return}
            if let detected {
                let old=settings.body.rect(size),fresh=detected.1.rect(size)
                if abs(old.minX-fresh.minX)>12 || abs(old.minY-fresh.minY)>12 || abs(old.width-fresh.width)>12 {
                    settings.list=detected.0;settings.body=detected.1
                    listOCRCache=FrameOCRCache();bodyOCRCache=FrameOCRCache()
                    try save();stableListFrames=0
                    if let reading=readingMail{inbox.set(reading.ticketID,.queued);try persistInbox()}
                    readingMail=nil
                    note("已根据当前 Foxmail 栏目重新校正列表和正文区域。")
                }
            }
            let listRect=settings.list.rect(size).integral,bodyRect=settings.body.rect(size).integral
            guard let listImage=image.cropping(to:listRect),let bodyImage=image.cropping(to:bodyRect) else{throw failure("截图区域不可用")}
            let needsBody=readingMail != nil || inbox.tickets.contains{$0.state == .queued}
            let previousList=listOCRCache,previousBody=bodyOCRCache,cacheTime=Date()
            let cached=try await Task.detached { () -> (FrameOCRCache,FrameOCRCache) in
                let list=try previousList.updating(listImage,now:cacheTime,includeDots:true)
                let body=needsBody ? try previousBody.updating(bodyImage,now:cacheTime,includeDots:false):previousBody
                return (list,body)
            }.value
            guard running,generation==epoch else{return}
            listOCRCache=cached.0;bodyOCRCache=cached.1
            let result=(cached.0.lines,cached.0.dots,needsBody ? cached.1.lines.filter{$0.rect.minY>3 && $0.rect.maxY<Double(bodyImage.height)-12}.map(\.text).joined(separator:"\n"):"")
            let current=try await currentWindow()
            guard running,generation==epoch else{return}
            guard current.frame==window.frame else{stableListFrames=0;readingMail?.stableFrames=0;tell("窗口位置发生变化，重新核对。");return}
            let now=Date();lastFrameAt=now;frames+=1;linesCount=result.0.count;lastScan=DateFormatter.localizedString(from:now,dateStyle:.none,timeStyle:.medium)
            preview=NSImage(cgImage:image,size:window.frame.size)
            let localRows=UnreadList.rows(result.0,dots:result.1,now:now)
            let sx=window.frame.width/Double(image.width),sy=window.frame.height/Double(image.height)
            let rows=localRows.map {r->InboxRow in var value=r;value.point=CGPoint(x:(r.point.x+listRect.minX)*sx,y:(r.point.y+listRect.minY)*sy);return value}
            let signature=Rules.hash(rows.map{$0.key+($0.unread ? "/unread":"/read")}.joined(separator:"\n"))
            stableListFrames=signature==listSignature ? stableListFrames+1:1;listSignature=signature
            ocrSummary="列表 \(result.0.count) 行；当前可见未读 \(rows.filter(\.unread).count) 封；待处理 \(inbox.waiting) 封。"
            if stableListFrames>=2,!rows.isEmpty {
                // Persist the complete unread batch before any click changes its flags.
                if inbox.observe(rows,now:now,includeExisting:settings.includeExistingUnread,firstSnapshot:firstInboxSnapshot){try persistInbox()}
                firstInboxSnapshot=false
            }
            // Discovery remains active, but a broken push channel must not consume
            // unread flags. Gate every reading/activation path after durable queuing.
            guard notificationAvailability.canOpenMail else {
                if let reading=readingMail {
                    inbox.set(reading.ticketID,.queued);try persistInbox();readingMail=nil
                }
                tell(notificationAvailability.detail);return
            }
            if let ready=inbox.tickets.first(where:{$0.state == .ready && $0.content != nil}) {
                try await sendInbox(ready,epoch:epoch);return
            }
            if let reading=readingMail,let ticket=inbox.tickets.first(where:{$0.id==reading.ticketID}),reading.shouldYield(to:rows,ticket:ticket,now:now) {
                lastReadRetry[ticket.id]=now
                inbox.set(ticket.id,.queued);try persistInbox();readingMail=nil
                tell("上一封未完成的任务已保留，优先处理当前未读邮件。");return
            }
            let unreadTicket=rows.filter(\.unread).compactMap{row in inbox.tickets.first{$0.state == .queued && $0.rowKey==row.key}}.first
            if readingMail == nil,unreadTicket == nil,stableListFrames>=2,
               let pending=inbox.tickets.first(where:{$0.canResumeSelected(in:rows,now:now) && UnreadList.receipt(result.2,expected:$0,now:now) != nil}) {
                inbox.set(pending.id,.reading)
                if let i=inbox.tickets.firstIndex(where:{$0.id==pending.id}){inbox.tickets[i].opened=true}
                try persistInbox();readingMail=ReadingMail(ticketID:pending.id,started:now)
                tell("正在恢复已排队邮件的完整正文，核对后只通知一次。")
                return
            }
            let retryTicket=inbox.tickets.first{ticket in
                now.timeIntervalSince(lastReadRetry[ticket.id] ?? .distantPast)>60 && ticket.retryRow(in:rows,now:now) != nil
            }
            let nextTicket=unreadTicket ?? retryTicket
            if settings.autoOpen,!active(current),
               (readingMail != nil || nextTicket != nil),
               await activateMailWhenIdle(current) {
                tell("正在切换到远程邮箱，准备处理未读邮件。");return
            }
            if var reading=readingMail,let ticket=inbox.tickets.first(where:{$0.id==reading.ticketID}) {
                if ticket.state.terminal {readingMail=nil;return}
                if let scrollAt=reading.scrollAt,now.timeIntervalSince(scrollAt)<3 {return}
                guard safeInputIdle(current) else {
                    readingMail=reading;tell("正在等待安全输入空闲并自动切换邮箱；正文未完成，不发送空提示。");return
                }
                // User input interrupts the page sequence; restart from the header.
                if [CGEventType.leftMouseDown,.rightMouseDown,.keyDown,.leftMouseDragged].contains(where:{CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:$0)<now.timeIntervalSince(reading.started)-0.5}) {
                    let before=reading.unreadBefore,confirmed=reading.selectionConfirmed
                    reading=ReadingMail(ticketID:ticket.id,started:now);reading.unreadBefore=before;reading.selectionConfirmed=confirmed
                }
                if !reading.selectionConfirmed,let before=reading.unreadBefore {
                    let cleared=rows.contains{$0.key==ticket.rowKey && !$0.unread} || rows.filter(\.unread).count<before
                    guard cleared else {
                        if now.timeIntervalSince(reading.started)>6 {
                            inbox.set(ticket.id,.queued);try persistInbox();readingMail=nil
                            tell("未读标记尚未消失，点击未生效；保留任务重新打开，不读取其他邮件。")
                        }else{readingMail=reading}
                        return
                    }
                    reading.selectionConfirmed=true
                }
                if reading.needsTop {
                    guard await scrollBody(current,toTop:true) else{tell("等待正文读取区域可用。");return}
                    reading.needsTop=false;reading.scrollAt=now;readingMail=reading;return
                }
                if now.timeIntervalSince(reading.started)<2{return}
                guard !result.2.isEmpty,!result.2.contains("正在加载") else{tell("等待邮件正文加载；不会先发送标题提示。");return}
                reading.stableFrames=MailPages.key(result.2)==MailPages.key(reading.pageText) ? reading.stableFrames+1:1
                reading.pageText=result.2
                guard reading.stableFrames>=2 else{readingMail=reading;return}
                if reading.verifying {
                    guard let finalReceipt=UnreadList.receipt(result.2,expected:ticket,now:now),finalReceipt.fingerprint==reading.receipt?.fingerprint else{
                        readingMail=ReadingMail(ticketID:ticket.id,started:now);tell("最终邮件身份未核对通过，重新读取正文。");return
                    }
                    let text=reading.pages.joined(separator:"\n")
                    guard !text.isEmpty,text.utf8.count<=900_000,let i=inbox.tickets.firstIndex(where:{$0.id==ticket.id}) else{return}
                    inbox.tickets[i].content=MailContent(fingerprint:finalReceipt.fingerprint,subject:finalReceipt.subject.isEmpty ? ticket.subject:finalReceipt.subject,text:text,sentAt:finalReceipt.sentAt)
                    inbox.set(ticket.id,.ready);try persistInbox();readingMail=nil
                    try await sendInbox(inbox.tickets[i],epoch:epoch);return
                }
                if reading.pages.isEmpty {
                    guard let receipt=UnreadList.receipt(result.2,expected:ticket,now:now) else{
                        if now.timeIntervalSince(reading.started)>25 {
                            lastReadRetry[ticket.id]=now;inbox.set(ticket.id,.queued);try persistInbox();readingMail=nil
                            tell("邮件身份核对暂未通过，任务已保存，稍后自动重试；优先处理新未读。");return
                        }
                        readingMail=reading;tell("尚未核对到这封邮件的发件人、完整标题和时间，继续保留待处理。");return
                    }
                    reading.receipt=receipt;reading.pages=[result.2];reading.previousPage=result.2
                } else {
                    // A changed, visible header belongs to another selection.
                    if let other=UnreadList.receipt(result.2,expected:ticket,now:now),other.fingerprint != reading.receipt?.fingerprint {
                        reading.needsTop=true;reading.pages=[];reading.receipt=nil;readingMail=reading;return
                    }
                    if MailPages.key(result.2)==MailPages.key(reading.previousPage) {reading.bottomChecks+=1}
                    else {
                        guard let merged=MailPages.merge(reading.pages.joined(separator:"\n"),result.2) else{
                            reading.needsTop=true;reading.pages=[];reading.receipt=nil;reading.stableFrames=0;readingMail=reading
                            tell("正文页间衔接未核对通过，重新读取；不发送截断内容。");return
                        }
                        reading.pages=[merged];reading.previousPage=result.2;reading.bottomChecks=0
                    }
                    if reading.bottomChecks>=2 {
                        guard await scrollBody(current,toTop:true) else{readingMail=reading;return}
                        reading.verifying=true;reading.scrollAt=now;reading.stableFrames=0;readingMail=reading
                        tell("正文已读到末尾，返回核对同一封邮件的标题与发件人。");return
                    }
                }
                guard reading.pages.joined(separator:"\n").utf8.count<900_000 else{tell("正文过长，保留等待核对。");return}
                if await scrollBody(current,toTop:false) {reading.scrollAt=now;reading.stableFrames=0}
                readingMail=reading;tell("正在逐页读取邮件正文，读到末尾并核对后才发送。");return
            }
            guard stableListFrames>=2 else{tell("正在连续核对未读标记与邮件位置。");return}
            guard hasToken,!transportPaused else {
                tell(transportPaused ? "微信通道被拒绝，待处理邮件已保留。请停止后修复 Token。":"未读邮件已排队。请停止监控并配置微信 Token。");return
            }
            if let ticket=nextTicket,
               let row=rows.first(where:{$0.key==ticket.rowKey && $0.unread}) ?? ticket.retryRow(in:rows,now:now) {
                if settings.autoOpen {
                    guard safeInputIdle(current) else{
                        tell("未读邮件已排队；等邮箱在前台且输入空闲后读取正文，不发送空提示。");return
                    }
                    inbox.set(ticket.id,.reading);if let i=inbox.tickets.firstIndex(where:{$0.id==ticket.id}){inbox.tickets[i].opened=true};try persistInbox()
                    if !(await clickPoint(row.point,window:current)) {
                        inbox.set(ticket.id,.queued)
                        if let i=inbox.tickets.firstIndex(where:{$0.id==ticket.id}){inbox.tickets[i].opened=ticket.opened}
                        try persistInbox();tell("本次未点击；邮件仍在待处理队列。");return
                    }
                }else{inbox.set(ticket.id,.reading);if let i=inbox.tickets.firstIndex(where:{$0.id==ticket.id}){inbox.tickets[i].opened=true};try persistInbox()}
                readingMail=ReadingMail(ticketID:ticket.id,started:Date())
                if settings.autoOpen && row.unread{readingMail?.unreadBefore=rows.filter(\.unread).count}
                if !row.unread{readingMail?.selectionConfirmed=true}
                tell(settings.autoOpen ? (row.unread ? "已提交未读邮件点击，等待未读标记消失并核对这封邮件的时间。":"正在恢复本工具已经打开但尚未发送的邮件；核对原邮件身份后继续读取。") : "请打开这封未读邮件，读取完整正文后才会发送。")
                return
            }
            // Recover a previously opened ticket from the current selected body,
            // without opening or discovering any historical read-mail row.
            if inbox.tickets.contains(where:{$0.state == .queued}),!result.2.isEmpty,
               let pending=inbox.tickets.first(where:{ticket in
                   guard ticket.state == .queued,UnreadList.receipt(result.2,expected:ticket,now:now) != nil else{return false}
                   return ticket.canResumeSelected(in:rows,now:now)
               }) {
                inbox.set(pending.id,.reading)
                if let i=inbox.tickets.firstIndex(where:{$0.id==pending.id}){inbox.tickets[i].opened=true}
                try persistInbox();readingMail=ReadingMail(ticketID:pending.id,started:now);return
            }
            if rows.isEmpty {
                tell("等待下一封未读邮件；请保持按“是否已读”排序并收起已读组。");return
            }
            tell(notificationNeedsUnlock ? "邮件正文已保存，通知等待本机授权；未读扫描继续运行。":(inbox.uncertain>0 ? "监控中；有发送结果待核对，请查看运行记录。":(active(current) ? "正在监控，等待下一封未读邮件。":"正在后台识别未读邮件；读取正文等待邮箱前台。")))
        }catch {
            stableListFrames=0;readingMail?.stableFrames=0
            if running,generation==epoch{tell("本轮未完成："+error.localizedDescription+"；待处理邮件保留。")}
        }
    }
    func safeInputIdle(_ window:SCWindow)->Bool {
        let flags=CGEventSource.flagsState(.combinedSessionState)
        return AXIsProcessTrusted() && active(window) && CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:CGEventType(rawValue:UInt32.max)!)>2
            && flags.intersection([.maskShift,.maskControl,.maskAlternate,.maskCommand]).isEmpty
            && !CGEventSource.buttonState(.combinedSessionState,button:.left) && !CGEventSource.buttonState(.combinedSessionState,button:.right)
    }
    func activateMailWhenIdle(_ window:SCWindow) async ->Bool {
        guard Date().timeIntervalSince(lastActivation)>8,SafariDevice.inputIdle() else{return false}
        if !SystemPortal.isAdapted {
            guard let approved=settings.approvedPage,PublicMailbox.inspect(window)?.digest==approved,
                  let pid=window.owningApplication?.processID,let app=NSRunningApplication(processIdentifier:pid) else{return false}
            lastActivation=Date()
            return app.activate()
        }
        guard AXIsProcessTrusted(),SafariDevice.state() == .remote,
              CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:CGEventType(rawValue:UInt32.max)!)>2,
              CGEventSource.flagsState(.combinedSessionState).intersection([.maskShift,.maskControl,.maskAlternate,.maskCommand]).isEmpty,
              !CGEventSource.buttonState(.combinedSessionState,button:.left),!CGEventSource.buttonState(.combinedSessionState,button:.right),
              let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:SystemPortal.browserID) else{return false}
        let front=NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard !["com.apple.SecurityAgent","com.apple.loginwindow","com.apple.systempreferences"].contains(front) else{return false}
        lastActivation=Date()
        let configuration=NSWorkspace.OpenConfiguration();configuration.activates=true
        do {
            _ = try await NSWorkspace.shared.openApplication(at:url,configuration:configuration)
            if let focused=SafariDevice.window(){_ = AXUIElementPerformAction(focused,kAXRaiseAction as CFString)}
            try? await Task.sleep(nanoseconds:300_000_000)
            return active(window)
        }catch{return false}
    }
    func scrollBody(_ window:SCWindow,toTop:Bool) async ->Bool {
        guard safeInputIdle(window) else{return false}
        let rect=settings.body.rect(window.frame.size)
        let p=CGPoint(x:window.frame.minX+rect.midX,y:window.frame.minY+rect.minY+rect.height*0.78)
        var element:AXUIElement?
        guard active(window,at:p),AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(p.x),Float(p.y),&element) == .success,let element else{return false}
        var pid:pid_t=0;guard AXUIElementGetPid(element,&pid) == .success,pid==window.owningApplication?.processID else{return false}
        guard let move=CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:p,mouseButton:.left),
              let wheel=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:toTop ? 32000:Int32(-rect.height*0.18),wheel2:0,wheel3:0) else{return false}
        wheel.location=p;move.flags=[];wheel.flags=[];move.post(tap:.cghidEventTap)
        try? await Task.sleep(nanoseconds:100_000_000)
        guard running,active(window,at:p) else{return false}
        wheel.post(tap:.cghidEventTap);return true
    }
    func sendInbox(_ ticket:InboxTicket,epoch:Int) async throws {
        guard let content=ticket.content,!content.text.isEmpty else{throw failure("正文尚未读取完成，未发送") }
        guard content.text.count<=19_000 else{tell("完整正文超过微信通道长度限制，已保存待处理；不会截断发送。");return}
        if let previous=inbox.lastSubmission,Date().timeIntervalSince(previous)<13 {tell("完整正文已保存，等待微信通道发送间隔。");return}
        guard notificationAvailability.canOpenMail else{tell(notificationAvailability.detail);return}
        guard let secret=notificationSecret else{return}
        guard !secret.isEmpty else{throw failure("微信 Token 尚未配置")}
        guard running,generation==epoch else{return}
        let fingerprint=content.fingerprint
        // This disk write is a gate. Never submit if durable intent cannot be saved.
        guard let url=ledgerURL else{throw failure("邮件队列未就绪")}
        var intent=inbox;intent.lastSubmission=Date()
        let (updated,send)=try InboxSendGate.prepare(intent,id:ticket.id,fingerprint:fingerprint){try Storage.write($0,to:url)}
        inbox=updated;queuedCount=inbox.waiting;uncertainCount=inbox.uncertain
        guard send else{readingMail=nil;tell("这封邮件已有发送记录，已跳过重复通知。");return}
        guard running,generation==epoch else{inbox.set(ticket.id,.queued);inbox.delivered.removeValue(forKey:fingerprint);try persistInbox();readingMail=nil;return}
        let report=await pushDetailed(token:secret,title:content.subject,body:content.notification,alarm:settings.night,mailContent:true,sentAt:content.sentAt,eventID:content.fingerprint)
        let result=report.outcome
        if let i=inbox.tickets.firstIndex(where:{$0.id==ticket.id}){inbox.tickets[i].deliveryReport=report}
        inbox.finish(ticket.id,result)
        if result=="Accepted"{inbox.unreadSeen[ticket.rowKey]=false}
        try persistInbox();readingMail=nil
        if result=="Rejected"{transportPaused=true}
        if running,generation==epoch {
            note(result=="Accepted" ? "这一封邮件的通知已被服务受理，去重记录已保存。":"这一封通知未确认成功："+report.reason+" 原记录已保留，未自动重复发送。")
        }
    }
}
