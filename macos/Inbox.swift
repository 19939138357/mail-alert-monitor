import Foundation
import AppKit
import ImageIO

struct InboxRow {
    var sender:String
    var subject:String
    var timeLabel:String
    var day:String
    var unread:Bool
    var point:CGPoint
    var occurrence:Int=0
    var baseKey:String {
        // Relative labels change every minute and must not create fresh messages.
        let time=Rules.matches("^(?:[0-9]+(?:分钟|小时|秒)前|刚刚)$",Rules.compact(timeLabel)).isEmpty ? Rules.compact(timeLabel):"relative"
        return Rules.hash(Rules.compact(sender).lowercased()+"/"+Rules.compact(subject)+"/"+day+"/"+time)
    }
    var key:String {baseKey+"/"+String(occurrence)}
    var event:MailEvent? {let events=Rules.titles(subject);return events.count==1 ? events.first:nil}
}

// A source-specific OCR ambiguity seen in the real Foxmail list. This is used
// only for finding a candidate; the body must still contain an exact mailbox.
enum MailIdentity {
    static func senderKey(_ value:String)->String {
        let raw=Rules.compact(value).lowercased()
        return raw=="report@examp1e.com" ? "report@example.com":raw
    }
    static func senderChoices(_ value:String)->[String] {
        let raw=Rules.compact(value).lowercased(),key=senderKey(value)
        return raw==key ? [raw]:[raw,key]
    }
}

enum UnreadList {
    struct Dot {var center:CGPoint;var size:CGSize}
    static func dots(_ image:CGImage)->[Dot] {
        let width=image.width,height=image.height
        guard width>0,height>0,width*height<=32_000_000 else{return []}
        var bytes=[UInt8](repeating:0,count:width*height*4)
        let drawn=bytes.withUnsafeMutableBytes{raw->Bool in
            guard let context=CGContext(data:raw.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else{return false}
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height));return true
        }
        guard drawn else{return []}
        var flags=[UInt8](repeating:0,count:width*height)
        for i in flags.indices {
            let p=i*4,r=Int(bytes[p]),g=Int(bytes[p+1]),b=Int(bytes[p+2])
            if b>145 && g>65 && r<170 && b-r>45 && g-r>12 {flags[i]=1}
        }
        var result:[Dot]=[]
        for i in flags.indices where flags[i]==1 {
            var stack=[i],count=0,minX=width,maxX=0,minY=height,maxY=0
            flags[i]=0
            while let p=stack.popLast() {
                let x=p%width,y=p/width;count+=1;minX=min(minX,x);maxX=max(maxX,x);minY=min(minY,y);maxY=max(maxY,y)
                for (dx,dy) in [(1,0),(-1,0),(0,1),(0,-1)] {
                    let nx=x+dx,ny=y+dy
                    if nx>=0,nx<width,ny>=0,ny<height {
                        let q=ny*width+nx;if flags[q]==1{flags[q]=0;stack.append(q)}
                    }
                }
            }
            let w=maxX-minX+1,h=maxY-minY+1
            // Small, nearly round blue indicators, never the large selected row.
            if count>=5,w>=3,h>=3,w<=32,h<=32,Double(w)/Double(h)>0.55,Double(w)/Double(h)<1.8,Double(count)/Double(w*h)>0.35 {
                result.append(Dot(center:CGPoint(x:Double(minX+maxX)/2,y:Double(minY+maxY)/2),size:CGSize(width:w,height:h)))
            }
        }
        return result
    }
    static func rows(_ lines:[OCRLine],dots:[Dot],now:Date)->[InboxRow] {
        let sorted=lines.sorted{$0.rect.minY<$1.rect.minY}
        var result:[InboxRow]=[]
        for sender in sorted {
            let rawName=sender.text.trimmingCharacters(in:.whitespacesAndNewlines)
            let inlineTime=Rules.matches("([0-9]{1,2}:[0-9]{2}|[0-9]+(?:分钟|小时|秒)前|刚刚)$",rawName).first?[1] ?? ""
            let name=inlineTime.isEmpty ? rawName:String(rawName.dropLast(inlineTime.count)).trimmingCharacters(in:.whitespaces)
            guard !name.isEmpty,name.count<=160,sender.rect.height>=5,
                  !["发件人", "收件人", "排序", "今天", "昨天", "邮件列表", "收件箱"].contains(where:{name.hasPrefix($0)}),
                  Rules.matches("^[0-9: /年 月日分钟前小时秒-]+$",name).isEmpty else{continue}
            let h=sender.rect.height
            // Bold unread senders have taller Vision boxes. Their descenders can
            // nearly touch the subject; compare baselines rather than a 1px gap.
            guard let title=sorted.first(where:{$0.rect.minY>sender.rect.minY+h*0.85 && $0.rect.minY-sender.rect.maxY<=max(12,h*2) && abs($0.rect.minX-sender.rect.minX)<=max(10,h*1.5) && $0.rect.width>=h*2}) else{continue}
            // The subject is below a sender, and another sender is not inside that gap.
            guard title.rect.minY-sender.rect.minY<=h*3.5 else{continue}
            let blue=dots.contains{dot in dot.center.x<sender.rect.minX && sender.rect.minX-dot.center.x<=h*5 && abs(dot.center.y-sender.rect.midY)<=h && dot.size.height<=h*1.6}
            let time=inlineTime.isEmpty ? (sorted.first{$0.rect.minX>=sender.rect.maxX-2 && abs($0.rect.midY-sender.rect.midY)<h && !Rules.matches("(?:[0-9]{1,2}:[0-9]{2}|[0-9]+(?:分钟|小时|秒)前|刚刚)",Rules.compact($0.text)).isEmpty}?.text ?? ""):inlineTime
            let looksLikeSender=blue || name.contains("@") || !time.isEmpty || name.caseInsensitiveCompare("Cacti-All") == .orderedSame
            guard looksLikeSender else{continue}
            var day=Rules.day(now)
            for heading in sorted where heading.rect.minY<sender.rect.minY {
                if heading.text.contains("昨天"){day=Rules.day(now.addingTimeInterval(-86400))}
                else if heading.text.contains("今天"){day=Rules.day(now)}
                else if let d=Rules.matches("(20[0-9]{2})[年/-]([0-9]{1,2})[月/-]([0-9]{1,2})",heading.text).first {
                    day=String(format:"%04d-%02d-%02d",Int(d[1])!,Int(d[2])!,Int(d[3])!)
                }
            }
            result.append(InboxRow(sender:name,subject:title.text,timeLabel:time,day:day,unread:blue,point:CGPoint(x:sender.rect.minX+min(100,sender.rect.width/2),y:sender.rect.midY)))
        }
        // Distinct equal-looking rows stay distinct within the visible list.
        var counts:[String:Int]=[:]
        for i in result.indices.reversed(){let key=result[i].baseKey;result[i].occurrence=counts[key,default:0];counts[key,default:0]+=1}
        return result
    }
    static func subjectPrefix(_ text:String)->String {
        let value=Rules.compact(text).replacingOccurrences(of:"[（(]?(?:确认码|验证码).*$",with:"",options:.regularExpression).replacingOccurrences(of:"\\.{2,}$|…+$",with:"",options:.regularExpression)
        return String(value.prefix(80))
    }
    struct Receipt:Equatable {var fingerprint:String;var code:String?;var sentAt:String;var subject:String=""}
    static func notificationSubject(_ header:[String],expected:InboxTicket)->String {
        let prefix=subjectPrefix(expected.subject)
        guard !prefix.isEmpty,let index=header.firstIndex(where:{Rules.compact($0).contains(prefix)}) else{return expected.subject}
        func clean(_ line:String)->String {
            line.replacingOccurrences(of:"^(?:主题|Subject)\\s*[:：]\\s*",with:"",options:[.regularExpression,.caseInsensitive])
                .trimmingCharacters(in:.whitespacesAndNewlines.union(CharacterSet(charactersIn:"★☆")))
        }
        var parts=[clean(header[index])]
        for line in header.dropFirst(index+1).prefix(7) {
            let value=Rules.compact(line)
            if value.contains("@") || value.lowercased()==Rules.compact(expected.sender).lowercased() ||
               value.hasPrefix("发给") || ["隐藏信息","显示信息"].contains(value) ||
               !Rules.matches("(?i)^(?:发件人|收件人|抄送|密送|时间|发送时间|大小|From|To|Cc|Bcc|Date|Size|Message-ID)[:：]",value).isEmpty ||
               !Rules.matches("^20[0-9]{2}[-/年][0-9]",value).isEmpty {break}
            let continuation=clean(line)
            if !continuation.isEmpty{parts.append(continuation)}
        }
        let subject=parts.joined()
        return Rules.compact(subject).hasPrefix(prefix) ? subject:expected.subject
    }
    static func receipt(_ text:String,expected:InboxTicket,now:Date)->Receipt? {
        let lines=text.components(separatedBy:.newlines).filter{!Rules.compact($0).isEmpty}
        // Expanded recipient lists can exceed sixteen lines. Stop at the actual
        // body when recognizable, rather than cutting the mail header mid-way.
        let bodyStart=lines.firstIndex{line in
            let value=Rules.compact(line)
            return value=="告警恢复" || ["消息:","查询时间:","文件名:","当前状态:"].contains{value.hasPrefix($0)}
        }
        let metadataEnd=lines.firstIndex{!Rules.matches("^(?:大小|Size)[:：]",Rules.compact($0)).isEmpty}.map{$0+1}
        let header=Array(lines.prefix(min(metadataEnd ?? bodyStart ?? 64,64))),joined=Rules.compact(header.joined(separator:"\n"))
        let subject=subjectPrefix(expected.subject),sender=Rules.compact(expected.sender).lowercased()
        var verifiedSender=sender
        let senderMatch:Bool
        if sender.contains("@") {
            let senderHeader=header.map{Rules.compact($0)}.joined(separator:"\n")
            let exact=MailIdentity.senderChoices(sender).filter{choice in
                let escaped=NSRegularExpression.escapedPattern(for:choice)
                return !Rules.matches("(?i)(?<![a-z0-9_.+\\-])"+escaped+"(?![a-z0-9_.\\-])",senderHeader).isEmpty
            }
            senderMatch = exact.count==1
            if let actual=exact.first{verifiedSender=actual}
        }else{senderMatch=joined.lowercased().contains(sender)}
        guard subject.count>=3,joined.contains(subject),senderMatch else{return nil}
        let dates=Rules.matches("(20[0-9]{2})[-/年]([0-9]{1,2})[-/月]([0-9]{1,2})日?(?:[（(][^）)]{1,8}[）)])?([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?",joined)
        let unique=Set(dates.map{d in String(format:"%04d-%02d-%02d %02d:%02d:%02d",Int(d[1])!,Int(d[2])!,Int(d[3])!,Int(d[4])!,Int(d[5])!,Int(d[6]) ?? 0)})
        guard unique.count==1,let date=unique.first else{return nil}
        guard let timestamp=Rules.dateFormat("yyyy-MM-dd HH:mm:ss").date(from:date),timestamp.timeIntervalSince(now)<120,
              expected.matchesSentTime(timestamp) else{return nil}
        let messageID=Rules.matches("(?i)Message-ID[:：]\\s*<([^<>\\s]+)>",text).first?.last
        let fullSubject=Rules.compact(header.first{Rules.compact($0).contains(subject)} ?? expected.subject).replacingOccurrences(of:"^(?:主题|Subject)[:：]",with:"",options:[.regularExpression,.caseInsensitive])
        // Prefer server identity when visible; otherwise use the verified mail header.
        // Ignore presentation-only stars and confirmation-code wrapping in the
        // identity. Keep the complete original text in the notification itself.
        let identitySubject=subjectPrefix(fullSubject).trimmingCharacters(in:CharacterSet(charactersIn:"★☆"))
        let fingerprint=Rules.hash(messageID.map{"message-id/"+$0} ?? (verifiedSender+"/"+date+"/"+identitySubject))
        let code=expected.event.flatMap{Rules.code(text,expected:$0,now:now)}
        return Receipt(fingerprint:fingerprint,code:code,sentAt:date,subject:notificationSubject(header,expected:expected))
    }
}

enum InboxState:String,Codable {
    case queued,reading,ready,sending,accepted,rejected,uncertain,duplicate
    var terminal:Bool {[Self.accepted,.uncertain,.duplicate].contains(self)}
    var label:String {
        switch self {case .queued:return "排队中";case .reading:return "读取中";case .ready:return "待发送";case .sending:return "发送中";case .accepted:return "服务已受理";case .rejected:return "通道已拒绝";case .uncertain:return "结果待核对";case .duplicate:return "已去重"}
    }
}
struct InboxTicket:Codable {
    var id:String
    var rowKey:String
    var sender:String
    var subject:String
    var timeLabel:String
    var day:String
    var occurrence:Int
    var discovered:Date
    var state:InboxState = .queued
    var fingerprint:String?
    var content:MailContent?
    var opened:Bool?
    var deliveryReport:PushReport?
    var receivedConfirmedAt:Date?
    var event:MailEvent? {let events=Rules.titles(subject);return events.count==1 ? events.first:nil}
    func matchesSentTime(_ sent:Date)->Bool {
        let label=Rules.compact(timeLabel)
        if label=="刚刚"{return abs(sent.timeIntervalSince(discovered))<=600}
        if let relative=Rules.matches("^([0-9]+)(分钟|小时|秒)前$",label).first,let count=Double(relative[1]) {
            let unit:Double=relative[2]=="小时" ? 3600:(relative[2]=="分钟" ? 60:1)
            // Foxmail's relative label can remain cached while the remote window
            // is inactive. It is still sufficient to reject same-title history.
            let upper=discovered.addingTimeInterval(-count*unit)
            let lower=upper.addingTimeInterval(relative[2]=="小时" ? -unit:0)
            return sent>=lower.addingTimeInterval(-600) && sent<=upper.addingTimeInterval(600)
        }
        if !Rules.matches("^[0-9]{1,2}:[0-9]{2}$",label).isEmpty,
           let expected=Rules.dateFormat("yyyy-MM-dd HH:mm").date(from:day+" "+label) {
            return abs(sent.timeIntervalSince(expected))<=120
        }
        return abs(sent.timeIntervalSince(discovered))<=600
    }
    var hasReliableTime:Bool {
        let label=Rules.compact(timeLabel)
        return label=="刚刚" || !Rules.matches("^(?:[0-9]+(?:分钟|小时|秒)前|[0-9]{1,2}:[0-9]{2})$",label).isEmpty
    }
    func canResumeSelected(in rows:[InboxRow],now:Date)->Bool {
        state == .queued && (opened==true || (hasReliableTime && rows.filter{matchesRow($0,now:now)}.count==1))
    }
    func matchesRow(_ row:InboxRow,now:Date)->Bool {
        guard MailIdentity.senderKey(row.sender)==MailIdentity.senderKey(sender),
              UnreadList.subjectPrefix(row.subject)==UnreadList.subjectPrefix(subject) else{return false}
        let label=Rules.compact(row.timeLabel)
        if label==Rules.compact(timeLabel) && row.key==rowKey{return true}
        if label=="刚刚"{return matchesSentTime(now)}
        if let r=Rules.matches("^([0-9]+)(分钟|小时|秒)前$",label).first,let count=Double(r[1]) {
            let unit:Double=r[2]=="小时" ? 3600:(r[2]=="分钟" ? 60:1)
            let upper=now.addingTimeInterval(-count*unit)
            if matchesSentTime(upper){return true}
            // Hour labels describe an interval rather than an exact hour.
            if r[2]=="小时" {
                for offset in stride(from:60.0,through:unit,by:60) where matchesSentTime(upper.addingTimeInterval(-offset)){return true}
            }
            return false
        }
        guard let date=Rules.dateFormat("yyyy-MM-dd HH:mm").date(from:row.day+" "+label) else{return false}
        return matchesSentTime(date)
    }
    // Resume only a mail that this monitor already opened from the unread queue.
    // Never discover or tour arbitrary read history. Ambiguous rows stay queued.
    func retryRow(in rows:[InboxRow],now:Date)->InboxRow? {
        guard state == .queued,opened==true,
              now.timeIntervalSince(discovered)>=0,now.timeIntervalSince(discovered)<48*3600 else{return nil}
        let candidates=rows.filter{matchesRow($0,now:now)}
        return candidates.count==1 ? candidates.first:nil
    }
}
struct InboxLedger:Codable {
    var lastSubmission:Date?
    var version=2
    var tickets:[InboxTicket]=[]
    var unreadSeen:[String:Bool]=[:]
    var delivered:[String:String]=[:]
    var legacySent:Set<String>=[]
    @discardableResult mutating func observe(_ rows:[InboxRow],now:Date,includeExisting:Bool=true,firstSnapshot:Bool=false)->Bool {
        let priorCount=tickets.count,priorSeen=unreadSeen
        for row in rows {
            let wasUnread=unreadSeen[row.key] ?? false
            defer{unreadSeen[row.key]=row.unread}
            guard row.unread,!wasUnread else{continue}
            let candidates=(0..<priorCount).filter{!tickets[$0].state.terminal && tickets[$0].occurrence==row.occurrence && tickets[$0].matchesRow(row,now:now)}
            if candidates.count==1,let i=candidates.first {
                // Refresh the click position/key when time typography or the
                // previously misrecognized sender changes. Keep the original
                // discovery time, content and external-delivery identity.
                tickets[i].rowKey=row.key
                continue
            }
            guard !tickets.contains(where:{$0.rowKey==row.key && !$0.state.terminal}) else{continue}
            if firstSnapshot && !includeExisting {continue}
            // A business event/title is not a mail identity. Deduplicate only
            // after verifying this particular mail's sender, timestamp and body.
            let subject=row.subject.replacingOccurrences(of:"((?:确认码|验证码)\\s*[：:]?\\s*)[0-9０-９ ]{4,}",with:"$1[已隐藏]",options:.regularExpression)
            tickets.append(InboxTicket(id:UUID().uuidString,rowKey:row.key,sender:row.sender,subject:subject,timeLabel:row.timeLabel,day:row.day,occurrence:row.occurrence,discovered:now))
        }
        return priorCount != tickets.count || priorSeen != unreadSeen
    }
    var waiting:Int {tickets.filter{!$0.state.terminal}.count}
    var uncertain:Int {tickets.filter{$0.state == .uncertain && $0.receivedConfirmedAt==nil}.count}
    mutating func confirmReceived(_ id:String,now:Date)->Bool {
        guard let i=tickets.firstIndex(where:{$0.id==id && $0.state == .uncertain && $0.content != nil && $0.receivedConfirmedAt==nil}) else{return false}
        // Receipt confirmation is separate evidence. Keep the original unknown
        // transport outcome and its no-replay fingerprint unchanged.
        tickets[i].receivedConfirmedAt=now
        return true
    }
    mutating func recover() {
        // Previous title-based exclusions recorded an unread baseline without
        // creating a ticket. Allow those still-unread mails into the queue.
        for key in Array(unreadSeen.keys) where !tickets.contains(where:{$0.rowKey==key}) {
            unreadSeen.removeValue(forKey:key)
        }
        for i in tickets.indices {
            if tickets[i].state.terminal || tickets[i].state == .sending,let content=tickets[i].content,
               let originalOutcome=delivered[content.fingerprint],
               let sent=Rules.dateFormat("yyyy-MM-dd HH:mm:ss").date(from:content.sentAt) {
                // Alias the actual already-delivered body, never rewrite or
                // discard its old key. This also preserves old mistaken row
                // associations without replaying that external notification.
                var captured=tickets[i]
                captured.day=Rules.day(sent);captured.timeLabel=Rules.dateFormat("HH:mm").string(from:sent)
                if let identity=UnreadList.receipt(content.text,expected:captured,now:max(sent,captured.discovered)) {
                    if delivered[identity.fingerprint]==nil{delivered[identity.fingerprint]=originalOutcome=="sending" ? "uncertain":originalOutcome}
                }
            }
            if tickets[i].state.terminal,let content=tickets[i].content,
               let sent=Rules.dateFormat("yyyy-MM-dd HH:mm:ss").date(from:content.sentAt),!tickets[i].matchesSentTime(sent) {
                // Keep every external delivery record. Reconsider only the
                // currently-unread row that an older build attached incorrectly.
                unreadSeen.removeValue(forKey:tickets[i].rowKey)
            }
            if tickets[i].state == .sending {tickets[i].state = .uncertain;if let key=tickets[i].fingerprint{delivered[key]=InboxState.uncertain.rawValue}}
            else if tickets[i].state == .reading || tickets[i].state == .ready {tickets[i].opened=true;tickets[i].state = tickets[i].content == nil ? .queued:.ready}
        }
    }
    mutating func set(_ id:String,_ state:InboxState,fingerprint:String?=nil) {
        guard let i=tickets.firstIndex(where:{$0.id==id}) else{return}
        tickets[i].state=state;if let fingerprint{tickets[i].fingerprint=fingerprint}
    }
    mutating func commitSend(_ id:String,fingerprint:String)->Bool {
        guard let ticket=tickets.first(where:{$0.id==id}),!ticket.state.terminal,ticket.state != .sending else{return false}
        if delivered[fingerprint] != nil {set(id,.duplicate,fingerprint:fingerprint);return false}
        set(id,.sending,fingerprint:fingerprint);delivered[fingerprint]=InboxState.sending.rawValue;return true
    }
    mutating func finish(_ id:String,_ outcome:String) {
        let state:InboxState=outcome=="Accepted" ? .accepted:(outcome=="Rejected" ? .rejected:.uncertain)
        set(id,state)
        if let key=tickets.first(where:{$0.id==id})?.fingerprint {
            // A definite rejection can be tried after the channel has been repaired.
            if state == .rejected{delivered.removeValue(forKey:key)}else{delivered[key]=state.rawValue}
        }
    }
}

struct ReadingMail {
    var ticketID:String
    var started:Date
    var receipt:UnreadList.Receipt?
    var stableFrames=0
    var pageText=""
    var pages:[String]=[]
    var previousPage=""
    var bottomChecks=0
    var scrollAt:Date?
    var needsTop=true
    var verifying=false
    var unreadBefore:Int?
    var selectionConfirmed=false
    func shouldYield(to rows:[InboxRow],ticket:InboxTicket,now:Date)->Bool {
        receipt == nil && rows.contains{$0.unread && $0.key != ticket.rowKey} && now.timeIntervalSince(started)>20
    }
}

struct MailContent:Codable,Equatable {
    var fingerprint:String
    var subject:String
    var text:String
    var sentAt:String
    var notification:String {text}
}

// Merge overlapping viewports; never substitute a title for missing content.
enum MailPages {
    static func key(_ text:String)->String {Rules.compact(text)}
    static func merge(_ existing:String,_ page:String)->String? {
        if key(existing)==key(page){return existing}
        let a=existing.components(separatedBy:.newlines).filter{!key($0).isEmpty}
        let b=page.components(separatedBy:.newlines).filter{!key($0).isEmpty}
        guard !a.isEmpty,!b.isEmpty else{return nil}
        for i in a.indices.reversed() where i>=a.count/2 {
            for j in b.indices where j<=b.count/2 && key(a[i]).count>=12 && key(a[i])==key(b[j]) {
                // A unique substantial line near the end anchors the overlap.
                guard a.filter({key($0)==key(a[i])}).count==1,b.filter({key($0)==key(b[j])}).count==1 else{continue}
                let prefix=Array(a.prefix(i+1)),suffix=Array(b.dropFirst(j+1))
                return (prefix+suffix).joined(separator:"\n")
            }
        }
        // Vision can split a wrapped line differently after scrolling. Find a
        // unique long overlapping text run, ignoring punctuation only for matching.
        func mapped(_ text:String)->([Character],[Int],[Character]) {
            let raw=Array(text);var letters:[Character]=[],positions:[Int]=[]
            for (i,ch) in raw.enumerated() where ch.isLetter || ch.isNumber {
                for c in String(ch).lowercased(){letters.append(c);positions.append(i)}
            }
            return (letters,positions,raw)
        }
        let (ak,ap,ar)=mapped(existing), (bk,bp,br)=mapped(page)
        let span=40
        if ak.count>=span,bk.count>=span {
            let astr=String(ak),bstr=String(bk)
            for end in stride(from:ak.count,through:max(span,ak.count/3),by:-1) {
                let needle=String(ak[(end-span)..<end])
                guard astr.components(separatedBy:needle).count==2,bstr.components(separatedBy:needle).count==2,
                      let r=bstr.range(of:needle) else{continue}
                let matchedEnd=bstr.distance(from:bstr.startIndex,to:r.upperBound)
                guard matchedEnd<=max(span+16,bk.count*3/4) else{continue}
                let left=String(ar.prefix(ap[end-1]+1)),right=String(br.dropFirst(bp[matchedEnd-1]+1))
                return left+right
            }
        }
        return nil
    }
}

enum InboxSendGate {
    static func prepare(_ ledger:InboxLedger,id:String,fingerprint:String,save:(InboxLedger)throws->Void)throws->(InboxLedger,Bool) {
        var next=ledger;let submit=next.commitSend(id,fingerprint:fingerprint)
        try save(next)
        return (next,submit)
    }
}
