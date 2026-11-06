import Foundation
import Vision
import AppKit
import Security
import LocalAuthentication
import CryptoKit

struct Region: Codable, Equatable {
    var x: Double; var y: Double; var w: Double; var h: Double
    var valid: Bool { [x,y,w,h].allSatisfy { $0.isFinite } && x >= 0 && y >= 0 && w > 0.02 && h > 0.02 && x+w <= 1.001 && y+h <= 1.001 }
    func rect(_ size: CGSize) -> CGRect { CGRect(x:x*size.width,y:y*size.height,width:w*size.width,height:h*size.height) }
}
struct OCRLine { var text: String; var rect: CGRect }
struct SecretReadGate {
    private(set) var request:UUID?
    private var started:Date?
    mutating func begin(now:Date)->UUID? {
        guard request == nil else{return nil}
        let id=UUID();request=id;started=now;return id
    }
    mutating func finish(_ id:UUID)->Bool {
        guard request==id else{return false}
        invalidate();return true
    }
    mutating func expire(_ id:UUID,now:Date)->Bool {
        guard request==id,let started,now.timeIntervalSince(started)>=5 else{return false}
        invalidate();return true
    }
    mutating func invalidate(){request=nil;started=nil}
}
struct FrameOCRCache {
    var fingerprint:String?
    var capturedAt=Date.distantPast
    var lines:[OCRLine]=[]
    var dots:[UnreadList.Dot]=[]
    static func fingerprint(_ image:CGImage)->String? {
        guard image.width>0,image.height>0,image.width*image.height<=32_000_000 else{return nil}
        var bytes=[UInt8](repeating:0,count:image.width*image.height*4)
        let drawn=bytes.withUnsafeMutableBytes{buffer->Bool in
            guard let context=CGContext(data:buffer.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else{return false}
            context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return true
        }
        guard drawn else{return nil}
        // Exact pixels, including image geometry. No sampled-image comparison:
        // even a one-pixel unread indicator change must invalidate the cache.
        return "\(image.width)x\(image.height)/"+SHA256.hash(data:Data(bytes)).map{String(format:"%02x",$0)}.joined()
    }
    func reusable(_ key:String?,now:Date)->Bool {
        key != nil && key==fingerprint && now.timeIntervalSince(capturedAt)>=0 && now.timeIntervalSince(capturedAt)<30
    }
    func updating(_ image:CGImage,now:Date,includeDots:Bool)throws->Self {
        let key=Self.fingerprint(image)
        if reusable(key,now:now){return self}
        return Self(fingerprint:key,capturedAt:now,lines:try recognize(image),dots:includeDots ? UnreadList.dots(image):[])
    }
}
enum MailboxLayout {
    static func regions(_ lines:[OCRLine],size:CGSize,list:Region,body:Region)->(Region,Region)? {
        let sorts=lines.filter{Rules.compact($0.text).hasPrefix("排序")}
        guard sorts.count==1,let sort=sorts.first else{return nil}
        let headers=lines.filter{line in
            line.rect.minX>sort.rect.minX+size.width*0.20 && line.rect.width>sort.rect.height*3 &&
            line.rect.height>sort.rect.height*1.1 &&
            line.rect.minY>=sort.rect.minY-sort.rect.height*0.3 &&
            line.rect.minY<=sort.rect.minY+sort.rect.height*1.4 && Rules.compact(line.text).count>=4
        }
        guard let header=headers.min(by:{$0.rect.minX<$1.rect.minX}) else{return nil}
        func snap(_ v:Double)->Double {(v/8).rounded()*8}
        let left=snap(sort.rect.minX-sort.rect.height*0.8),split=snap(header.rect.minX-sort.rect.height*0.7)
        let top=snap(min(sort.rect.minY,header.rect.minY)-sort.rect.height*0.5)
        let right=min(size.width-6,(body.x+body.w)*size.width),bottom=min(size.height-6,(body.y+body.h)*size.height)
        guard left>=0,split-left>size.width*0.18,right-split>size.width*0.18,bottom-top>size.height*0.3 else{return nil}
        let a=Region(x:left/size.width,y:top/size.height,w:(split-left-6)/size.width,h:(bottom-top)/size.height)
        let b=Region(x:(split+6)/size.width,y:top/size.height,w:(right-split-6)/size.width,h:(bottom-top)/size.height)
        return a.valid && b.valid ? (a,b):nil
    }
}
struct MailEvent: Codable, Equatable {
    var kind: String; var day: String; var batch: Int
    var id: String { "\(kind)/\(day)/\(batch)" }
    var title: String { kind == "alert" ? "告警抽查" : "电话抽查" }
    var digits: Int { kind == "alert" ? 6 : 4 }
    func newer(than other: MailEvent) -> Bool { day > other.day || (day == other.day && batch > other.batch) }
}
struct MailRow { var event: MailEvent; var point: CGPoint }
enum Rules {
    static func normal(_ text: String) -> String { text.precomposedStringWithCompatibilityMapping }
    static func compact(_ text: String) -> String { normal(text).components(separatedBy:.whitespacesAndNewlines).joined() }
    static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern:pattern) else { return [] }
        return regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).map { m in
            (0..<m.numberOfRanges).map { i in Range(m.range(at:i),in:text).map { String(text[$0]) } ?? "" }
        }
    }
    static func dateFormat(_ format: String) -> DateFormatter {
        let f=DateFormatter(); f.locale=Locale(identifier:"en_US_POSIX"); f.timeZone=TimeZone(identifier:"Asia/Shanghai"); f.dateFormat=format; f.isLenient=false; return f
    }
    static func day(_ date: Date) -> String { dateFormat("yyyy-MM-dd").string(from:date) }
    static func titles(_ text: String) -> [MailEvent] {
        matches("(告警抽查邮件|电话抽查邮件|客服电话检查)(20[0-9]{2})年([0-9]{1,2})月([0-9]{1,2})日([0-9]{1,3})次",compact(text)).compactMap { m in
            guard let y=Int(m[2]),let mo=Int(m[3]),let d=Int(m[4]),let n=Int(m[5]),n>0 else { return nil }
            let day=String(format:"%04d-%02d-%02d",y,mo,d)
            guard let dt=dateFormat("yyyy-MM-dd").date(from:day),self.day(dt)==day else { return nil }
            return MailEvent(kind:m[1]=="告警抽查邮件" ? "alert":"phone",day:day,batch:n)
        }
    }
    static func sender(_ text: String) -> Bool {
        let value=normal(text).replacingOccurrences(of:"[\\t ]",with:"",options:.regularExpression).replacingOccurrences(of:"report@example/com",with:"report@example.com",options:.caseInsensitive)
        return !matches("(?i)(?<![a-z0-9_.+\\-])report@example\\.com(?![a-z0-9_.\\-])",value).isEmpty
    }
    static func rows(_ lines: [OCRLine], now: Date) -> [MailRow] {
        let all: [MailRow] = lines.compactMap { line in
            let ts=titles(line.text)
            guard ts.count==1,ts[0].day<=day(now),line.rect.width>=40,line.rect.height>=5,
                lines.contains(where:{ sender($0.text) && $0.rect.minY<=line.rect.minY+2 && line.rect.minY-$0.rect.minY<=max(32,line.rect.height*3) && abs($0.rect.minX-line.rect.minX)<=max(25,line.rect.height*2) }) else { return nil }
            return MailRow(event:ts[0],point:CGPoint(x:line.rect.minX+min(line.rect.width/2,100),y:line.rect.midY))
        }
        let counts=Dictionary(grouping:all,by:{$0.event.id})
        return all.filter{counts[$0.event.id]?.count==1}.sorted{$1.event.newer(than:$0.event)}
    }
    static func code(_ text: String, expected: MailEvent, now: Date) -> String? {
        guard sender(text),Set(titles(text).map(\.id))==Set([expected.id]) else { return nil }
        let value=compact(text)
        let label=expected.kind=="alert" ? "确认码" : "(?:确认码|验证码)"
        guard let regex=try? NSRegularExpression(pattern:label),let hit=regex.firstMatch(in:value,range:NSRange(value.startIndex...,in:value)),let range=Range(hit.range,in:value) else { return nil }
        let header=String(value[..<range.lowerBound]).replacingOccurrences(of:"(?<=[0-9])一(?=[0-9]{2})",with:"-",options:.regularExpression)
        let dates=matches("(?<![0-9])(20[0-9]{2}-[0-9]{2}-[0-9]{2})([0-9]{2}:[0-9]{2})(?![0-9])",header)
        guard dates.count==1,dates[0][1]==expected.day,let sent=dateFormat("yyyy-MM-dd HH:mm").date(from:dates[0][1]+" "+dates[0][2]),now.timeIntervalSince(sent)>=(-120),now.timeIntervalSince(sent)<900 else { return nil }
        // Inspect the whole label line: extra digits, decimal suffixes and mixed candidates are rejected.
        let lines=normal(text).components(separatedBy:.newlines)
        var candidates=Set<String>()
        for (i,line) in lines.enumerated() {
            let c=compact(line)
            guard let h=regex.firstMatch(in:c,range:NSRange(c.startIndex...,in:c)),let r=Range(h.range,in:c) else { continue }
            var tail=String(c[r.upperBound...]).trimmingCharacters(in:CharacterSet(charactersIn:"：:，,=。"))
            if tail.isEmpty,i+1<lines.count { tail=compact(lines[i+1]) }
            let pattern="^([0-9]{\(expected.digits)})(?:[。！!，,；;]|$)"
            let hits=matches(pattern,tail)
            guard hits.count==1,matches("[0-9]+",tail).count==1 else { return nil }
            candidates.insert(hits[0][1])
        }
        return candidates.count==1 ? candidates.first:nil
    }
    static func hash(_ value: String) -> String { SHA256.hash(data:Data(value.utf8)).map{String(format:"%02x",$0)}.joined() }
}
struct Ledger: Codable {
    var version=1
    var baselines: [String:MailEvent]=[:]
    var records: [String:String]=[:]
    mutating func consider(_ event: MailEvent, now: Date) -> Bool {
        let key=Rules.hash(event.id)
        if records[key] != nil { return false }
        guard let base=baselines[event.kind] else { baselines[event.kind]=event; records[key]="Baseline"; return false }
        return event.day==Rules.day(now) && event.newer(than:base)
    }
    mutating func record(_ event: MailEvent, _ status: String) { records[Rules.hash(event.id)]=status }
}
enum Storage {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MailAlertMonitorOpenSource", isDirectory: true)
    }
    static func prepare() throws { try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]) }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data=try JSONEncoder().encode(value); try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
}
enum Secrets {
    enum AccessError:LocalizedError {
        case requiresUser,keychainStatus(OSStatus)
        var errorDescription:String? {
            switch self {
            case .requiresUser:return "钥匙串要求本人验证"
            case .keychainStatus(let status):return "钥匙串返回错误（\(status)）"
            }
        }
    }
    static let base: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"org.example.mailalertmonitor",kSecAttrAccount as String:"pushplus"]
    static func isConfigured() -> Bool {
        // Metadata only: launching an updated app must not wait for secret-access UI.
        var query=base;query[kSecReturnAttributes as String]=true;query[kSecMatchLimit as String]=kSecMatchLimitOne
        let context=LAContext();context.interactionNotAllowed=true
        query[kSecUseAuthenticationContext as String]=context
        var item:CFTypeRef?
        let status=SecItemCopyMatching(query as CFDictionary,&item)
        return status==errSecSuccess || status==errSecInteractionNotAllowed
    }
    static func read(interactive:Bool=true) throws -> String {
        var query=base;query[kSecReturnData as String]=true;query[kSecMatchLimit as String]=kSecMatchLimitOne
        if !interactive {
            let context=LAContext();context.interactionNotAllowed=true
            query[kSecUseAuthenticationContext as String]=context
            // File-based macOS keychain items may ignore LAContext. The scan
            // loop also never awaits this call if the service fails to return.
            query[kSecUseAuthenticationUI as String]=kSecUseAuthenticationUIFail
        }
        var item: CFTypeRef?;let status=SecItemCopyMatching(query as CFDictionary,&item)
        if !interactive,[errSecInteractionNotAllowed,errSecAuthFailed].contains(status){throw AccessError.requiresUser}
        if status==errSecItemNotFound { return "" }
        guard status==errSecSuccess else{throw AccessError.keychainStatus(status)}
        guard let data=item as? Data,let value=String(data:data,encoding:.utf8) else{throw failure("微信配置格式无法读取")}
        return value
    }
    static func save(_ token: String) throws {
        guard !Rules.matches("^[A-Za-z0-9_-]{16,128}$",token).isEmpty else { throw failure("Token 格式不正确，请粘贴 PushPlus 个人中心的 Token。") }
        let attrs=[kSecValueData as String:Data(token.utf8)]
        let status=SecItemUpdate(base as CFDictionary,attrs as CFDictionary)
        if status==errSecItemNotFound { var item=base;attrs.forEach{item[$0.key]=$0.value};guard SecItemAdd(item as CFDictionary,nil)==errSecSuccess else { throw failure("钥匙串保存失败") } }
        else if status != errSecSuccess { throw failure("钥匙串更新失败") }
    }
}
func failure(_ message: String) -> NSError { NSError(domain:"MailMonitor",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
func recognize(_ image: CGImage) throws -> [OCRLine] {
    let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate
    request.recognitionLanguages=["zh-Hans","en-US"];request.usesLanguageCorrection=false
    try VNImageRequestHandler(cgImage:image,options:[:]).perform([request])
    return (request.results ?? []).compactMap { item in
        guard let text=item.topCandidates(1).first else { return nil }
        let r=item.boundingBox
        return OCRLine(text:text.string,rect:CGRect(x:r.minX*Double(image.width),y:(1-r.maxY)*Double(image.height),width:r.width*Double(image.width),height:r.height*Double(image.height)))
    }.sorted{ $0.rect.minY < $1.rect.minY }
}
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?)->Void) { completionHandler(nil) }
}
enum NotificationText {
    static func title(_ subject:String,sentAt:String?=nil,alarm:Bool,eventID:String)->String {
        let name=subject.components(separatedBy:.whitespacesAndNewlines).filter{!$0.isEmpty}.joined(separator:" ")
        let prefix=sentAt.flatMap{Rules.dateFormat("yyyy-MM-dd HH:mm:ss").date(from:$0)}.map{Rules.dateFormat("MM-dd HH:mm").string(from:$0)+"｜"} ?? ""
        let rawID=String(eventID.prefix(16))
        let identity=Rules.matches("^[A-Za-z0-9_-]{8,16}$",rawID).isEmpty ? String(Rules.hash(eventID).prefix(16)):rawID
        let suffix=alarm ? " 【夜间告警】[事件:\(identity)]":""
        let room=max(1,100-prefix.count-suffix.count)
        let visible=name.count>room ? String(name.prefix(room-1))+"…":name
        return prefix+visible+suffix
    }
}
struct PushReport:Codable,Equatable {
    var outcome:String
    var reason:String
    var receipt:String?
    static func response(_ data:Data,status:Int?)->Self {
        guard let status else{return Self(outcome:"Uncertain",reason:"未取得有效 HTTP 响应，可能已被服务受理。")}
        guard status==200 else{return Self(outcome:status>=500 ? "Uncertain":"Rejected",reason:"推送接口返回 HTTP \(status)。")}
        guard let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let code=object["code"] as? Int else {
            return Self(outcome:"Uncertain",reason:"推送接口响应无法解析，可能已被服务受理。")
        }
        let rawReceipt=(object["data"] as? String) ?? ((object["data"] as? [String:Any])?["shortCode"] as? String)
        let receipt=rawReceipt.flatMap{Rules.matches("^[A-Za-z0-9_-]{8,128}$",$0).isEmpty ? nil:$0}
        return Self(outcome:code==200 ? "Accepted":"Rejected",reason:code==200 ? "推送服务已受理，手机收件需另行核对。":"推送服务拒绝请求（代码 \(code)）。",receipt:code==200 ? receipt:nil)
    }
    static func transport(_ error:Error)->Self {
        let value=error as NSError
        let detail:String
        if value.domain==NSURLErrorDomain && value.code==NSURLErrorTimedOut {detail="等待推送接口响应超时，可能已被服务受理。"}
        else if value.domain==NSURLErrorDomain && value.code==NSURLErrorNotConnectedToInternet {detail="网络连接不可用，未取得推送确认。"}
        else {detail="推送连接中断（网络代码 \(value.code)），未取得确认。"}
        // Never persist raw server messages, URLs or localized errors: any of
        // them can reflect the token or the original message body.
        return Self(outcome:"Uncertain",reason:detail)
    }
}
func pushDetailed(token: String,title: String,body: String,alarm: Bool, mailContent:Bool=false,sentAt:String?=nil,eventID:String?=nil) async -> PushReport {
    var request=URLRequest(url:URL(string:"https://www.pushplus.plus/send")!);request.httpMethod="POST";request.timeoutInterval=25
    request.setValue("application/json; charset=utf-8",forHTTPHeaderField:"Content-Type")
    let actualTitle=NotificationText.title(title,sentAt:sentAt,alarm:alarm,eventID:eventID ?? UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased())
    request.httpBody=try? JSONSerialization.data(withJSONObject:["token":token,"title":actualTitle,"content":mailContent ? body:actualTitle+"\n"+body,"template":"txt","channel":"wechat","timestamp":Int(Date().addingTimeInterval(120).timeIntervalSince1970*1000)])
    let session=URLSession(configuration:.ephemeral,delegate:NoRedirect(),delegateQueue:nil);defer{session.finishTasksAndInvalidate()}
    do {
        let (data,response)=try await session.data(for:request)
        var report=PushReport.response(data,status:(response as? HTTPURLResponse)?.statusCode)
        if report.receipt==token{report.receipt=nil}
        return report
    } catch {return PushReport.transport(error)}
}
func push(token: String,title: String,body: String,alarm: Bool, mailContent:Bool=false,sentAt:String?=nil,eventID:String?=nil) async -> String {
    await pushDetailed(token:token,title:title,body:body,alarm:alarm,mailContent:mailContent,sentAt:sentAt,eventID:eventID).outcome
}
