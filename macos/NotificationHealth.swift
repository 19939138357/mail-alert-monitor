import Foundation

// A configured item is not proof that this process can read it or send mail.
// Resolve all blocking flags before considering a cached secret usable.
enum NotificationAvailability: Equatable {
    case missingConfiguration, checking, needsAuthorization, authorizing, rejected, ready

    static func resolve(configured:Bool,hasSecret:Bool,needsAuthorization:Bool,authorizing:Bool,rejected:Bool)->Self {
        guard configured else{return .missingConfiguration}
        if rejected{return .rejected}
        if authorizing{return .authorizing}
        if needsAuthorization{return .needsAuthorization}
        return hasSecret ? .ready:.checking
    }
    var canOpenMail:Bool {self == .ready}
    var requiresAttention:Bool {self != .ready && self != .checking}
    var title:String {
        switch self {
        case .missingConfiguration:return "微信推送未配置"
        case .checking:return "正在检查微信推送"
        case .needsAuthorization,.authorizing,.rejected:return "微信推送已暂停"
        case .ready:return "微信推送可用"
        }
    }
    var detail:String {
        switch self {
        case .missingConfiguration:return "仍在发现并保存未读任务，暂不自动打开邮件；请先配置微信通知。"
        case .checking:return "正在检查本机通知配置；未读任务继续保存，确认可用后才自动打开。"
        case .needsAuthorization:return "通知配置暂不可用；未读任务继续保存，暂不自动打开。请点“授权通知”。"
        case .authorizing:return "正在等待系统返回通知授权；未读任务继续保存，暂不自动打开。"
        case .rejected:return "微信通道已明确拒绝通知；任务和完整正文已保留，修复配置后继续。"
        case .ready:return "通知配置可用；完整正文被服务受理后仍需核对手机收件。"
        }
    }
}

// The caller owns the incident identity and the local presentation. Silencing
// an incident never changes the channel state or any delivery record.
struct NotificationAlertPolicy {
    private var incident:String?
    private var lastAlert:Date?
    private var silenced=false

    mutating func shouldAlert(incident current:String?,now:Date)->Bool {
        guard let current else{reset();return false}
        if current != incident {
            incident=current;lastAlert=now;silenced=false
            return true
        }
        guard !silenced else{return false}
        guard let previous=lastAlert else{lastAlert=now;return true}
        let elapsed=now.timeIntervalSince(previous)
        // A clock correction must not postpone an unresolved warning forever.
        guard elapsed>=60 || elapsed<0 else{return false}
        lastAlert=now
        return true
    }
    mutating func silence(){if incident != nil{silenced=true}}
    mutating func reset(){incident=nil;lastAlert=nil;silenced=false}
}

// Isolated policy and ledger contracts only: no GUI, keychain, disk or network.
enum NotificationHealthTests {
    static func run()throws->Int {
        var checks=0
        func check(_ condition:Bool,_ message:String)throws {
            guard condition else{throw failure("notification health: "+message)}
            checks+=1
        }
        for bits in 0..<32 {
            let configured=bits & 1 != 0,hasSecret=bits & 2 != 0
            let needs=bits & 4 != 0,authorizing=bits & 8 != 0,rejected=bits & 16 != 0
            let state=NotificationAvailability.resolve(configured:configured,hasSecret:hasSecret,
                needsAuthorization:needs,authorizing:authorizing,rejected:rejected)
            let allowed=configured && hasSecret && !needs && !authorizing && !rejected
            try check(state.canOpenMail==allowed,"all configuration combinations fail closed: \(bits)")
            try check(state.requiresAttention == (state != .ready && state != .checking),"attention classification: \(bits)")
            try check(!state.title.isEmpty && !state.detail.isEmpty,"every state explains its current action: \(bits)")
        }
        try check(NotificationAvailability.resolve(configured:false,hasSecret:true,needsAuthorization:true,authorizing:true,rejected:true) == .missingConfiguration,"missing configuration outranks stale cache and flags")
        try check(NotificationAvailability.resolve(configured:true,hasSecret:true,needsAuthorization:true,authorizing:true,rejected:true) == .rejected,"known rejection cannot be hidden by a cached secret")
        try check(NotificationAvailability.resolve(configured:true,hasSecret:true,needsAuthorization:true,authorizing:true,rejected:false) == .authorizing,"explicit authorization remains visible until it completes")
        try check(NotificationAvailability.resolve(configured:true,hasSecret:true,needsAuthorization:true,authorizing:false,rejected:false) == .needsAuthorization,"authorization requirement overrides a cached secret")
        try check(NotificationAvailability.resolve(configured:true,hasSecret:false,needsAuthorization:false,authorizing:false,rejected:false) == .checking,"metadata alone never enables opening mail")

        let now=Date(timeIntervalSince1970:1_700_000_000)
        var alert=NotificationAlertPolicy()
        try check(!alert.shouldAlert(incident:nil,now:now),"healthy startup is silent")
        alert.silence()
        try check(alert.shouldAlert(incident:"authorization",now:now),"silencing without an incident cannot mute a future fault")
        try check(!alert.shouldAlert(incident:"authorization",now:now),"one frame cannot repeat the warning")
        try check(!alert.shouldAlert(incident:"authorization",now:now.addingTimeInterval(59.999)),"same fault is throttled for a full minute")
        try check(alert.shouldAlert(incident:"authorization",now:now.addingTimeInterval(60)),"unresolved fault repeats at sixty seconds")
        try check(!alert.shouldAlert(incident:"authorization",now:now.addingTimeInterval(119)),"repeat starts a fresh throttle interval")
        alert.silence()
        try check(!alert.shouldAlert(incident:"authorization",now:now.addingTimeInterval(600)),"silence applies to the ongoing incident")
        try check(alert.shouldAlert(incident:"rejected",now:now.addingTimeInterval(601)),"a different fault alerts immediately despite previous silence")
        alert.silence()
        try check(!alert.shouldAlert(incident:nil,now:now.addingTimeInterval(602)),"recovery clears the incident without an alert")
        try check(alert.shouldAlert(incident:"rejected",now:now.addingTimeInterval(603)),"the same reason after recovery is a new incident")
        alert.reset()
        try check(alert.shouldAlert(incident:"rejected",now:now.addingTimeInterval(604)),"stopping resets the warning episode")
        try check(alert.shouldAlert(incident:"rejected",now:now),"clock rollback rebases a pending warning")
        try check(!alert.shouldAlert(incident:"rejected",now:now.addingTimeInterval(1)),"clock rollback does not cause a warning on every following frame")

        func row(_ subject:String,_ time:String)->InboxRow {
            InboxRow(sender:"synthetic@example.invalid",subject:subject,timeLabel:time,
                day:"2026-10-23",unread:true,point:CGPoint(x:90,y:120))
        }
        let priorRow=row("已保存完整正文","13:00"),freshRow=row("新未读邮件","14:16")
        var baseline=InboxLedger();baseline.observe([priorRow],now:now)
        let readyID=baseline.tickets[0].id
        let readyContent=MailContent(fingerprint:"synthetic-ready",subject:priorRow.subject,
            text:"这是合成的完整正文。",sentAt:"2026-10-23 13:00:00")
        baseline.tickets[0].content=readyContent;baseline.tickets[0].opened=true
        baseline.set(readyID,.ready)
        baseline.delivered["synthetic-accepted"]="accepted"
        baseline.delivered["synthetic-uncertain"]="uncertain"
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        let blocked:[NotificationAvailability]=[.missingConfiguration,.checking,.needsAuthorization,.authorizing,.rejected]
        for state in blocked {
            var ledger=baseline
            try check(ledger.observe([priorRow,freshRow],now:now),"blocked channel still discovers the unread batch")
            // The scanner persists observation before consulting canOpenMail.
            let persisted=try encoder.encode(ledger)
            let restored=try JSONDecoder().decode(InboxLedger.self,from:persisted)
            try check(restored.tickets.count==2 && restored.tickets.contains{$0.rowKey==freshRow.key && $0.state == .queued && $0.opened != true},"new unread task survives persistence without being opened")
            try check(!state.canOpenMail,"blocked policy prevents the scanner's next opening action")
            try check(restored.tickets.first{$0.id==readyID}?.state == .ready && restored.tickets.first{$0.id==readyID}?.content==readyContent && restored.tickets.first{$0.id==readyID}?.opened==true,"previously opened complete mail remains ready and intact")
            try check(restored.delivered==baseline.delivered,"discovery while paused cannot clear previous delivery outcomes")
            try check(!ledger.observe([priorRow,freshRow],now:now.addingTimeInterval(1)),"continued blocked scanning does not duplicate tasks")
        }

        let restoredHealth=NotificationAvailability.resolve(configured:true,hasSecret:true,
            needsAuthorization:false,authorizing:false,rejected:false)
        try check(restoredHealth.canOpenMail && !restoredHealth.requiresAttention,"successful authorization resumes normal work")
        var recovered=baseline,savedIntent:Data?
        let (sending,submit)=try InboxSendGate.prepare(recovered,id:readyID,fingerprint:readyContent.fingerprint){saved in
            savedIntent=try encoder.encode(saved)
        }
        recovered=sending
        try check(submit && savedIntent != nil,"restored ready mail creates one durable submission intent")
        let intended=try JSONDecoder().decode(InboxLedger.self,from:savedIntent!)
        try check(intended.tickets.first{$0.id==readyID}?.state == .sending && intended.delivered[readyContent.fingerprint]=="sending","intent is persisted before a simulated transmission")
        recovered.finish(readyID,"Accepted")
        var repeatedWrites=0
        let (same,noResend)=try InboxSendGate.prepare(recovered,id:readyID,fingerprint:readyContent.fingerprint){_ in repeatedWrites+=1}
        try check(!noResend && repeatedWrites==1 && same.tickets.first{$0.id==readyID}?.state == .accepted,"a subsequent scan cannot submit the accepted message again")
        try check(same.delivered["synthetic-accepted"]=="accepted" && same.delivered["synthetic-uncertain"]=="uncertain","recovery retains all historical accepted and uncertain keys")

        // An uncertain delivery remains terminal; it does not freeze a separate
        // message or pretend that the original message was actually received.
        var uncertain=baseline
        let (pending,firstSubmit)=try InboxSendGate.prepare(uncertain,id:readyID,fingerprint:readyContent.fingerprint){_ in}
        uncertain=pending;uncertain.finish(readyID,"Uncertain")
        let (stillUncertain,retry)=try InboxSendGate.prepare(uncertain,id:readyID,fingerprint:readyContent.fingerprint){_ in}
        try check(firstSubmit && !retry && stillUncertain.uncertain==1,"unknown result is retained and never blindly retried")
        var afterRestart=try JSONDecoder().decode(InboxLedger.self,from:encoder.encode(stillUncertain));afterRestart.recover()
        try check(afterRestart.uncertain==1 && !afterRestart.commitSend(readyID,fingerprint:readyContent.fingerprint),"unknown delivery also remains protected after persistence and recovery")
        afterRestart.observe([freshRow],now:now)
        let distinct=afterRestart.tickets.first{$0.rowKey==freshRow.key}!
        let (_,distinctSubmit)=try InboxSendGate.prepare(afterRestart,id:distinct.id,fingerprint:"synthetic-distinct"){_ in}
        try check(restoredHealth.canOpenMail && distinctSubmit,"an unresolved old delivery does not freeze a different new message")

        let oldDeliveryKeys=afterRestart.delivered
        try check(!afterRestart.confirmReceived("missing-ticket",now:now),"confirmation cannot create a missing receipt")
        try check(!afterRestart.confirmReceived(distinct.id,now:now),"a queued message cannot be marked received")
        try check(afterRestart.confirmReceived(readyID,now:now) && afterRestart.uncertain==0,"explicit receipt confirmation resolves only the selected old warning")
        try check(afterRestart.tickets.first{$0.id==readyID}?.state == .uncertain && afterRestart.delivered==oldDeliveryKeys,"confirmation retains the actual transport outcome and every no-replay key")
        try check(!afterRestart.confirmReceived(readyID,now:now.addingTimeInterval(1)),"receipt confirmation is idempotent")
        var confirmed=try JSONDecoder().decode(InboxLedger.self,from:encoder.encode(afterRestart));confirmed.recover()
        try check(confirmed.uncertain==0 && confirmed.tickets.first{$0.id==readyID}?.receivedConfirmedAt==now,"receipt confirmation survives restart")
        try check(!confirmed.commitSend(readyID,fingerprint:readyContent.fingerprint),"receipt confirmation never enables another submission")
        var oldJSON=try JSONSerialization.jsonObject(with:encoder.encode(stillUncertain)) as! [String:Any]
        var oldTickets=oldJSON["tickets"] as! [[String:Any]]
        for i in oldTickets.indices{oldTickets[i].removeValue(forKey:"deliveryReport");oldTickets[i].removeValue(forKey:"receivedConfirmedAt")}
        oldJSON["tickets"]=oldTickets
        let oldLedger=try JSONDecoder().decode(InboxLedger.self,from:JSONSerialization.data(withJSONObject:oldJSON))
        try check(oldLedger.uncertain==1 && oldLedger.delivered==stillUncertain.delivered,"old ledgers remain unresolved until there is real receipt evidence")

        let accepted=PushReport.response(Data("{\"code\":200,\"data\":\"sample-receipt-001\"}".utf8),status:200)
        try check(accepted.outcome=="Accepted" && accepted.receipt=="sample-receipt-001","accepted responses retain the provider receipt")
        let nested=PushReport.response(Data("{\"code\":200,\"data\":{\"shortCode\":\"sample-receipt-002\"}}".utf8),status:200)
        try check(nested.receipt=="sample-receipt-002","nested provider receipt is also retained")
        let reflected=PushReport.response(Data("{\"code\":400,\"msg\":\"secret-token-example\",\"data\":\"secret-token-example\"}".utf8),status:200)
        try check(reflected.outcome=="Rejected" && reflected.receipt==nil && !reflected.reason.contains("secret-token"),"rejected response diagnostics never reflect server text or data")
        try check(PushReport.response(Data("not-json".utf8),status:200).outcome=="Uncertain","malformed response does not falsely prove a rejection")
        try check(PushReport.response(Data(),status:503).outcome=="Uncertain","server failure preserves possible prior acceptance")
        try check(PushReport.response(Data(),status:403).outcome=="Rejected","explicit HTTP rejection remains repairable")
        try check(PushReport.response(Data(),status:nil).outcome=="Uncertain","missing HTTP response retains unknown outcome")
        let timeout=PushReport.transport(NSError(domain:NSURLErrorDomain,code:NSURLErrorTimedOut,userInfo:[NSLocalizedDescriptionKey:"https://example.invalid/secret-token-example"]))
        try check(timeout.outcome=="Uncertain" && timeout.reason.contains("超时") && !timeout.reason.contains("secret-token"),"network timeout gets a safe persistent diagnosis without losing uncertainty")
        let unsafeReceipt=PushReport.response(Data("{\"code\":200,\"data\":\"https://example.invalid/secret-token\"}".utf8),status:200)
        try check(unsafeReceipt.outcome=="Accepted" && unsafeReceipt.receipt==nil,"only bounded opaque provider receipts may be persisted")
        return checks
    }
}
