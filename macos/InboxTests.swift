import Foundation
import AppKit
import ImageIO

enum InboxTests {
    static func run()throws->Int {
        var checks=0
        func check(_ condition:Bool,_ message:String)throws{guard condition else{throw failure("inbox: "+message)};checks+=1}
        let now=Rules.dateFormat("yyyy-MM-dd HH:mm:ss").date(from:"2026-10-09 09:30:00")!
        func row(_ subject:String,_ sender:String="report@example.com",time:String="09:20",unread:Bool=true,occurrence:Int=0)->InboxRow {
            InboxRow(sender:sender,subject:subject,timeLabel:time,day:"2026-10-09",unread:unread,point:CGPoint(x:90,y:120),occurrence:occurrence)
        }
        let batch=[row("告警抽查邮件2026年10月09日1次"),row("告警抽查邮件2026年10月09日2次"),row("告警抽查邮件2026年10月09日3次"),row("普通设备状态通知","Cacti-All"),row("普通工作邮件","其他发件人",time:"09:22")]
        var ledger=InboxLedger();ledger.observe(batch,now:now,firstSnapshot:true)
        try check(ledger.tickets.count==5,"all three alert batches and ordinary senders queued")
        ledger.observe(batch,now:now.addingTimeInterval(2));try check(ledger.tickets.count==5,"unchanged unread frame creates no duplicates")
        var exclude=InboxLedger();exclude.observe(batch,now:now,includeExisting:false,firstSnapshot:true);exclude.observe(batch,now:now)
        try check(exclude.tickets.isEmpty,"optional startup exclusion is stable")
        exclude.observe(batch+[row("新到工作邮件")],now:now.addingTimeInterval(3));try check(exclude.tickets.count==1,"new arrival after startup exclusion")
        var same=InboxLedger();let repeated=[row("相同主题",time:"09:20",occurrence:0),row("相同主题",time:"09:20",occurrence:1)]
        same.observe(repeated,now:now);try check(same.tickets.count==2,"two equal-looking rows do not collapse")
        try check(row("普通工作邮件",time:"2分钟前").key==row("普通工作邮件",time:"3分钟前").key,"relative time ticking does not create a new mail")
        let merged=[OCRLine(text:"report@example.com 2分钟前",rect:CGRect(x:40,y:20,width:300,height:15)),OCRLine(text:"普通工作邮件",rect:CGRect(x:40,y:40,width:200,height:15))]
        let mergedRows=UnreadList.rows(merged,dots:[UnreadList.Dot(center:CGPoint(x:28,y:27),size:CGSize(width:9,height:9))],now:now)
        try check(mergedRows.count==1 && mergedRows[0].sender=="report@example.com" && mergedRows[0].timeLabel=="2分钟前","merged sender and clock OCR is split before identity")
        let justNowLines=merged.map{line -> OCRLine in var copy=line;copy.text=copy.text.replacingOccurrences(of:"2分钟前",with:"刚刚");return copy}
        let justNowRows=UnreadList.rows(justNowLines,dots:[UnreadList.Dot(center:CGPoint(x:28,y:27),size:CGSize(width:9,height:9))],now:now)
        try check(justNowRows.first?.timeLabel=="刚刚" && justNowRows.first?.key==mergedRows.first?.key,"just-arrived time remains stable when it changes to minutes ago")
        let id=ledger.tickets[0].id;ledger.set(id,.reading)
        var read=batch;read[0].unread=false;ledger.observe(read,now:now)
        try check(ledger.tickets.first{$0.id==id}?.state == .reading,"click-to-read does not remove persisted ticket")
        var restart=try JSONDecoder().decode(InboxLedger.self,from:JSONEncoder().encode(ledger));restart.recover()
        try check(restart.tickets.first{$0.id==id}?.state == .queued && restart.waiting==5,"reading crash returns every ticket to queue")
        var sends=0
        for ticket in restart.tickets {
            let (next,send)=try InboxSendGate.prepare(restart,id:ticket.id,fingerprint:ticket.id){saved in
                try check(saved.tickets.first{$0.id==ticket.id}?.state == .sending,"durable sending intent precedes fake delivery")
            }
            restart=next;if send{sends+=1;restart.finish(ticket.id,"Accepted")}
        }
        try check(sends==5 && restart.waiting==0,"five messages receive five separate submissions")
        for ticket in restart.tickets {try check(!restart.commitSend(ticket.id,fingerprint:ticket.id),"accepted messages cannot be resubmitted")}
        var uncertain=InboxLedger();uncertain.observe([batch[0]],now:now);let uid=uncertain.tickets[0].id
        _=uncertain.commitSend(uid,fingerprint:"server-id-one")
        var recovered=try JSONDecoder().decode(InboxLedger.self,from:JSONEncoder().encode(uncertain));recovered.recover()
        try check(recovered.uncertain==1 && !recovered.commitSend(uid,fingerprint:"server-id-one"),"sending crash is retained as uncertain, never replayed")
        var rejected=InboxLedger();rejected.observe([batch[0]],now:now);let rid=rejected.tickets[0].id
        _=rejected.commitSend(rid,fingerprint:"reject-test");rejected.finish(rid,"Rejected")
        try check(rejected.waiting==1 && rejected.delivered["reject-test"]==nil,"definite rejection remains waiting")
        var duplicate=InboxLedger();duplicate.observe(repeated,now:now)
        _=duplicate.commitSend(duplicate.tickets[0].id,fingerprint:"same-message-id");duplicate.finish(duplicate.tickets[0].id,"Accepted")
        try check(!duplicate.commitSend(duplicate.tickets[1].id,fingerprint:"same-message-id") && duplicate.tickets[1].state == .duplicate,"read identity prevents duplicate notifications")
        var legacy=InboxLedger();legacy.legacySent=[Rules.hash(batch[0].event!.id)];legacy.observe(batch,now:now)
        try check(legacy.tickets.count==5,"legacy business title cannot exclude a distinct unread mail")
        var skipped=InboxLedger();skipped.unreadSeen[batch[0].key]=true;skipped.recover();skipped.observe([batch[0]],now:now)
        try check(skipped.tickets.count==1,"previously excluded unread baseline recovers into a real ticket")
        var ongoing=ReadingMail(ticketID:id,started:now.addingTimeInterval(-31))
        try check(ongoing.shouldYield(to:[batch[1]],ticket:ticketForYield(ledger,id:id),now:now),"stalled prior reading cannot block a new unread mail")
        ongoing.started=now
        try check(!ongoing.shouldYield(to:[batch[1]],ticket:ticketForYield(ledger,id:id),now:now),"active reading finishes before another mail")
        var redacted=InboxLedger();redacted.observe([row("客服电话检查2026年10月09日1次（确认码： 0843）")],now:now)
        try check(!redacted.tickets[0].subject.contains("0843"),"confirmation code not persisted in queue title")
        var ticket=ledger.tickets[0];ticket.timeLabel="09:25"
        let body="告警抽查邮件2026年10月09日1次\nreport@example.com\n2026-10-09 09:25\n确认码：063827"
        let receipt=UnreadList.receipt(body,expected:ticket,now:now)
        try check(receipt?.code=="063827","correct body and code")
        try check(receipt?.subject==ticket.subject,"notification subject comes from the verified heading")
        var wrappedSubjectTicket=ticket
        wrappedSubjectTicket.subject="客服电话检查2026年10月09日1次（确认码：[已隐藏]）"
        let wrappedHeading=["客服电话检查2026年10月09日1次（确认码：084","3）",wrappedSubjectTicket.sender,"2026-10-09 09:25","大小：3 KB","正文不是主题"]
        try check(UnreadList.notificationSubject(wrappedHeading,expected:wrappedSubjectTicket)=="客服电话检查2026年10月09日1次（确认码：0843）","wrapped confirmation code is retained in actual notification subject")
        try check(UnreadList.notificationSubject(["主题："+ticket.subject,"发给：另一位同事",ticket.sender,"2026-10-09 09:25"],expected:ticket)==ticket.subject,"subject extraction stops before plain recipient metadata")
        try check(UnreadList.notificationSubject(["其他邮件标题",ticket.sender],expected:ticket)==ticket.subject,"unmatched heading cannot replace the queued mail subject")
        try check(receipt?.fingerprint==Rules.hash("report@example.com/2026-10-09 09:25:00/"+UnreadList.subjectPrefix(ticket.subject)),"notification presentation leaves the existing delivery fingerprint unchanged")
        try check(UnreadList.receipt(body.replacingOccurrences(of:"1次",with:"2次"),expected:ticket,now:now)==nil,"old different body cannot be attached")
        try check(UnreadList.receipt(body.replacingOccurrences(of:"report@",with:"other@"),expected:ticket,now:now)==nil,"different sender body rejected")
        try check(UnreadList.receipt(body.replacingOccurrences(of:"report@",with:"xreport@"),expected:ticket,now:now)==nil,"sender substring cannot match a different mailbox")
        try check(UnreadList.receipt(body.replacingOccurrences(of:"2026-10-09 09:25",with:""),expected:ticket,now:now)==nil,"header date required for identity")
        var senderTypo=ticket;senderTypo.sender="report@examp1e.com"
        try check(UnreadList.receipt(body,expected:senderTypo,now:now)?.fingerprint==receipt?.fingerprint,"real list n/m OCR error recovers through exact body mailbox without changing identity")
        try check(UnreadList.receipt(body.replacingOccurrences(of:"report@",with:"xreport@"),expected:senderTypo,now:now)==nil,"OCR candidate cannot accept a mailbox substring")
        try check(UnreadList.receipt(body+"\nreport@examp1e.com",expected:senderTypo,now:now)==nil,"two contradictory mailbox candidates cannot be guessed")
        let missingSize=body+"\n查询时间：2026-10-09 09:24:59\n文件名：/mysql/test.ibd\n状态：异常"
        try check(UnreadList.receipt(missingSize,expected:ticket,now:now)?.fingerprint==receipt?.fingerprint,"synthetic query time is body metadata when the size label was not recognized")
        try check(UnreadList.receipt("告警抽查邮件2026年10月09日1次\nreport@example.com\n查询时间：2026-10-09 09:25",expected:ticket,now:now)==nil,"query time alone cannot prove the email header")
        try check(UnreadList.receipt(body+"\n时间：2026年10月09日（周五）09:25",expected:ticket,now:now)?.fingerprint==receipt?.fingerprint,"expanded Foxmail header repeats the same time without losing identity")
        try check(UnreadList.receipt(body+"\n正在加载…",expected:ticket,now:now)?.fingerprint==receipt?.fingerprint,"body loading noise does not change header identity")
        try check(UnreadList.receipt(body.replacingOccurrences(of:"1次\n",with:"1次★\n"),expected:ticket,now:now)?.fingerprint==receipt?.fingerprint,"presentation stars cannot create a second notification identity")
        let phoneTopic="客服电话检查2026年10月09日1次"
        var phoneTicket=ticket;phoneTicket.subject=phoneTopic+"（确认码：[已隐藏]）"
        let phoneOne=phoneTopic+"（确认码：1620）\nreport@example.com\n2026-10-09 09:25"
        let phoneWrapped=phoneOne.replacingOccurrences(of:"1620）",with:"162\n0）")
        try check(UnreadList.receipt(phoneOne,expected:phoneTicket,now:now)?.fingerprint==UnreadList.receipt(phoneWrapped,expected:phoneTicket,now:now)?.fingerprint,"phone title line wrapping cannot create a second notification identity")
        var priorDelivery=InboxLedger();priorDelivery.tickets=[ticket]
        priorDelivery.tickets[0].state = .accepted
        priorDelivery.tickets[0].content=MailContent(fingerprint:"legacy-body-key",subject:ticket.subject,text:body,sentAt:"2026-10-09 09:25:00")
        priorDelivery.delivered["legacy-body-key"]="accepted";priorDelivery.recover()
        try check(priorDelivery.delivered["legacy-body-key"]=="accepted" && priorDelivery.delivered[receipt!.fingerprint]=="accepted","upgrade preserves the old external receipt and aliases its normalized identity")
        let expanded=body.replacingOccurrences(of:"2026-10-09 09:25",with:(1...20).map{"收件人\($0)@example.invalid"}.joined(separator:"\n")+"\n时间：2026-10-09 09:25")
        try check(UnreadList.receipt(expanded,expected:ticket,now:now) != nil,"long expanded recipient header still includes the timestamp")
        try check(UnreadList.receipt(body.replacingOccurrences(of:"09:25",with:"09:26"),expected:ticket,now:now)?.fingerprint != receipt?.fingerprint,"same subject with distinct timestamps is distinct")
        try check(UnreadList.receipt(body.replacingOccurrences(of:"09:25",with:"08:25"),expected:ticket,now:now)==nil,"same-title historical mail cannot satisfy a new unread row")
        var relativeTicket=ticket;relativeTicket.timeLabel="5分钟前"
        try check(UnreadList.receipt(body,expected:relativeTicket,now:now) != nil,"relative unread time matches its actual mail header")
        try check(UnreadList.receipt(body.replacingOccurrences(of:"09:25",with:"08:25"),expected:relativeTicket,now:now)==nil,"cached relative time still rejects old same-title mail")
        var mistaken=InboxLedger();mistaken.tickets=[ticket];mistaken.unreadSeen[ticket.rowKey]=true
        mistaken.tickets[0].state = .accepted
        mistaken.tickets[0].content=MailContent(fingerprint:"old-sent",subject:ticket.subject,text:body,sentAt:"2026-10-09 08:25:00")
        mistaken.delivered["old-sent"]="accepted";mistaken.recover()
        try check(mistaken.unreadSeen[ticket.rowKey]==nil && mistaken.delivered["old-sent"]=="accepted","incorrect row association recovers without replaying an external notification")
        ongoing.started=now.addingTimeInterval(-60);ongoing.receipt=receipt
        try check(!ongoing.shouldYield(to:[batch[1]],ticket:ticket,now:now),"verified body reading is not abandoned merely because another unread arrived")
        let timestampInBody=body+"\n大小：4 KB\n检测时间：2026-10-09 09:24:59\n最近变更：2026-10-09 09:23"
        try check(UnreadList.receipt(timestampInBody,expected:ticket,now:now)?.fingerprint==receipt?.fingerprint,"body timestamps after Foxmail metadata do not invalidate the mail header")
        try check(UnreadList.receipt("告警抽查邮件2026年10月09日1次\nreport@example.com\n大小：4 KB\n检测时间：2026-10-09 09:25",expected:ticket,now:now)==nil,"body timestamp cannot substitute for missing header timestamp")
        var interrupted=ticket;interrupted.opened=true;interrupted.state = .queued
        let openedRow=row(interrupted.subject,time:"09:25",unread:false)
        try check(interrupted.retryRow(in:[openedRow],now:now) != nil,"interrupted unread task resumes even though its own click made it read")
        var unopened=interrupted;unopened.opened=false
        try check(unopened.retryRow(in:[openedRow],now:now)==nil,"unopened read history cannot be resumed")
        var oldInterrupted=interrupted;oldInterrupted.day="2026-10-08";oldInterrupted.discovered=now.addingTimeInterval(-86400)
        try check(oldInterrupted.retryRow(in:[openedRow],now:now)==nil,"prior-day history is never reopened during pending recovery")
        let midnight=Rules.dateFormat("yyyy-MM-dd HH:mm:ss").date(from:"2026-10-10 00:05:00")!
        var midnightTicket=interrupted;midnightTicket.timeLabel="23:55";midnightTicket.discovered=midnight.addingTimeInterval(-600)
        var midnightRow=openedRow;midnightRow.timeLabel="10分钟前";midnightRow.day="2026-10-10"
        try check(midnightTicket.retryRow(in:[midnightRow],now:midnight) != nil,"recent queued mail survives the midnight date change")
        try check(interrupted.retryRow(in:[openedRow,row(interrupted.subject,time:"08:25",unread:false)],now:now)?.timeLabel=="09:25","pending recovery rejects old equal-title mail")
        try check(interrupted.retryRow(in:[openedRow,openedRow],now:now)==nil,"ambiguous pending rows are kept queued")
        var clockTransition=InboxLedger()
        let justArrived=row("电话测试",time:"刚刚")
        try check(clockTransition.observe([justArrived],now:now),"first unread observation is durably dirty")
        try check(!clockTransition.observe([justArrived],now:now.addingTimeInterval(1)),"unchanged capture does not cause a redundant durable write")
        var clockRow=justArrived;clockRow.timeLabel="09:30"
        clockTransition.observe([clockRow],now:now.addingTimeInterval(60))
        try check(clockTransition.tickets.count==1 && clockTransition.tickets[0].rowKey==clockRow.key,"just-now to absolute time transition keeps the original pending task")
        var typoRow=clockRow;typoRow.sender="report@examp1e.com"
        clockTransition.observe([typoRow],now:now.addingTimeInterval(61))
        try check(clockTransition.tickets.count==1 && clockTransition.tickets[0].rowKey==typoRow.key,"same time sender OCR variant does not duplicate the pending mail")
        var manuallyRead=clockTransition.tickets[0];manuallyRead.opened=false
        var readClock=clockRow;readClock.unread=false
        try check(manuallyRead.canResumeSelected(in:[readClock],now:now.addingTimeInterval(61)),"a persisted unread ticket can complete if the user opened its exact selected body")
        try check(!manuallyRead.canResumeSelected(in:[readClock,readClock],now:now),"an unopened ambiguous historical row cannot recover a pending ticket")
        manuallyRead.timeLabel=""
        try check(!manuallyRead.canResumeSelected(in:[readClock],now:now),"an unopened task without reliable original time cannot use selected history")
        var hourTicket=interrupted;hourTicket.timeLabel="1小时前";hourTicket.discovered=now
        let inHour=now.addingTimeInterval(-80*60)
        try check(hourTicket.matchesSentTime(inHour),"hour label represents its real interval rather than a single rounded hour")
        try check(!hourTicket.matchesSentTime(now.addingTimeInterval(-3*3600)),"hour interval does not permit unrelated old mail")
        var nextDay=openedRow;nextDay.day="2026-10-10"
        try check(!interrupted.matchesRow(nextDay,now:now.addingTimeInterval(86400)),"equal time and title on a new day cannot steal yesterday's pending task")
        var recent=interrupted;recent.timeLabel="";recent.discovered=now
        try check(!recent.matchesSentTime(now.addingTimeInterval(-3600)),"missing list time cannot attach an old equal-title body")
        let layoutLines=[OCRLine(text:"排序:是否已读",rect:CGRect(x:534,y:322,width:180,height:26)),OCRLine(text:"Cacti-All设备上线",rect:CGRect(x:1216,y:336,width:440,height:38))]
        let layout=MailboxLayout.regions(layoutLines,size:CGSize(width:2012,height:1362),list:Settings().list,body:Settings().body)
        try check(layout != nil && layout!.0.x>0.25 && layout!.1.x>0.59,"moved Foxmail window relocates both list and body columns")
        try check(MailboxLayout.regions(layoutLines+[layoutLines[0]],size:CGSize(width:2012,height:1362),list:Settings().list,body:Settings().body)==nil,"ambiguous layout cannot silently move input regions")
        let dateLayoutLines=layoutLines.map{line->OCRLine in var copy=line;copy.text=copy.text.replacingOccurrences(of:"是否已读",with:"日期");return copy}
        try check(MailboxLayout.regions(dateLayoutLines,size:CGSize(width:2012,height:1362),list:Settings().list,body:Settings().body) != nil,"date-sorted mailbox still recalibrates the full clock column")
        let scrollingText=[layoutLines[0],OCRLine(text:"发件人：Cacti-All",rect:CGRect(x:1248,y:336,width:440,height:24))]
        try check(MailboxLayout.regions(scrollingText,size:CGSize(width:2012,height:1362),list:Settings().list,body:Settings().body)==nil,"scrolled body text cannot become a layout title")
        let msgid=body+"\nMessage-ID: <synthetic-001@example.invalid>"
        try check(UnreadList.receipt(msgid,expected:ticket,now:now)?.fingerprint==UnreadList.receipt(msgid+"\n额外正文",expected:ticket,now:now)?.fingerprint,"server Message-ID stays stable")
        let prior=Settings();var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(prior)) as! [String:Any]
        json.removeValue(forKey:"includeExistingUnread");json.removeValue(forKey:"browseEntireList")
        let migrated=try JSONDecoder().decode(Settings.self,from:JSONSerialization.data(withJSONObject:json))
        try check(migrated.includeExistingUnread && !migrated.browseEntireList,"existing settings retire read-history touring")
        let page1="主题：普通设备状态通知\nCacti-All\n2026-10-09 09:25\n设备名称：交换机001，保持原始数字\n业务说明：这是一封需要逐页读取的邮件\n告警数值：000063827，正文第一页"
        let page2="业务说明：这是一封需要逐页读取的邮件\n告警数值：000063827，正文第一页\n最后一行：恢复正常，延迟12毫秒"
        let combined=MailPages.merge(page1,page2)
        try check(combined?.contains("最后一行：恢复正常，延迟12毫秒")==true,"full body includes last viewport")
        try check(combined?.components(separatedBy:"业务说明：").count==2,"overlap is not repeated")
        try check(combined?.contains("000063827")==true,"body digits and leading zeros remain verbatim")
        try check(MailPages.merge(page1,"不属于这封邮件的正文") == nil,"unmatched pages never become partial notifications")
        try check(MailPages.merge("标题\nabcdefghijklmnopqrstuvwx0123456789ABCDEF\n需要替换的旧末尾", "分行开头\nabcdefghijklmnopqrstuvwx 0123456789\nABCDEF\n新的完整末尾")?.contains("新的完整末尾")==true,"wrapped OCR overlap preserves the complete next page")
        let content=MailContent(fingerprint:"complete-test",subject:"普通设备状态通知",text:combined!,sentAt:"2026-10-09 09:25:00")
        try check(content.notification==combined && !content.notification.contains("正文未核对完整"),"notification is the actual captured body")
        var durable=InboxLedger();durable.observe([batch[3]],now:now)
        durable.tickets[0].content=content;durable.tickets[0].state = .ready
        var restored=try JSONDecoder().decode(InboxLedger.self,from:JSONEncoder().encode(durable));restored.recover()
        try check(restored.tickets[0].state == .ready && restored.tickets[0].content?.text==combined,"complete content survives restart after unread disappears")
        var readOnly=InboxLedger();readOnly.observe([row("已读旧邮件",unread:false)],now:now)
        try check(readOnly.tickets.isEmpty,"historical read mails never enter queue")
        let acceptedID=restored.tickets[0].id
        _=restored.commitSend(acceptedID,fingerprint:content.fingerprint);restored.finish(acceptedID,"Accepted")
        restored.recover()
        try check(!restored.commitSend(acceptedID,fingerprint:content.fingerprint),"completed full-body mail is never resent")
        let sample=Bundle.main.url(forResource:"MailSample",withExtension:"png")!
        let data=try Data(contentsOf:sample)
        guard let source=CGImageSourceCreateWithData(data as CFData,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else{throw failure("sample")}
        let dots=UnreadList.dots(image),lines=try recognize(image),rows=UnreadList.rows(lines,dots:dots,now:now)
        let cached=try FrameOCRCache().updating(image,now:now,includeDots:true)
        try check(cached.reusable(FrameOCRCache.fingerprint(image),now:now.addingTimeInterval(2)),"unchanged fresh capture can reuse real OCR")
        try check(!cached.reusable(FrameOCRCache.fingerprint(image),now:now.addingTimeInterval(30)),"periodic OCR refresh remains bounded")
        let colorSpace=CGColorSpaceCreateDeviceRGB()
        let context=CGContext(data:nil,width:32,height:32,bitsPerComponent:8,bytesPerRow:128,space:colorSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:32,height:32))
        let noDot=context.makeImage()!
        context.setFillColor(NSColor.blue.cgColor);context.fill(CGRect(x:4,y:4,width:1,height:1))
        let changed=context.makeImage()!
        try check(FrameOCRCache.fingerprint(noDot) != FrameOCRCache.fingerprint(changed),"a one-pixel unread change invalidates the image cache")
        let left=changed.cropping(to:CGRect(x:0,y:0,width:16,height:32))!,right=changed.cropping(to:CGRect(x:16,y:0,width:16,height:32))!
        try check(FrameOCRCache.fingerprint(left) != FrameOCRCache.fingerprint(right),"different equal-sized crops cannot share a full-source provider fingerprint")
        try check(dots.count>=3,"synthetic mail fixture has blue unread dots")
        try check(rows.filter(\.unread).count==2,"both complete synthetic unread rows recognized; third subject is outside the image")
        try check(rows.filter(\.unread).allSatisfy{!$0.subject.contains("抽查")},"ordinary unread mail is not restricted to business subjects")
        // A failing save gate must never grant permission to call the sender.
        var failedSends=0
        do {let (_,send)=try InboxSendGate.prepare(ledger,id:id,fingerprint:"save-failure"){_ in throw failure("synthetic save failure")};if send{failedSends+=1}}
        catch{}
        try check(failedSends==0,"save failure blocks external submission")
        let titleLines=[OCRLine(text:"report@example.com",rect:CGRect(x:20,y:10,width:200,height:12)),OCRLine(text:"告警抽查邮件2026年10月09日1次",rect:CGRect(x:20,y:28,width:250,height:12)),OCRLine(text:"report@example.com",rect:CGRect(x:20,y:60,width:200,height:12)),OCRLine(text:"告警抽查邮件2026年10月09日2次",rect:CGRect(x:20,y:78,width:250,height:12))]
        try check(Rules.rows(titleLines,now:now).count==2,"legacy business parser keeps every batch, not just newest")
        print("PASS inbox \(checks) checks; synthetic unread sample: \(dots.count) markers, \(rows.filter(\.unread).count) unread rows; isolated fake sends only.")
        return checks
    }
    private static func ticketForYield(_ ledger:InboxLedger,id:String)->InboxTicket {ledger.tickets.first{$0.id==id}!}
}
