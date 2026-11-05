import Foundation
import AppKit
import Security
import LocalAuthentication

struct PortalCredentials: Codable {
    let username:String
    let password:String
    var valid:Bool { !username.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && username.count<=512 && !password.isEmpty && password.count<=4096 }
}
enum PortalVault {
    static let base:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"org.example.mailalertmonitor",kSecAttrAccount as String:"portal-login"]
    static func configured()->Bool {
        var q=base;q[kSecReturnAttributes as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        let context=LAContext();context.interactionNotAllowed=true;q[kSecUseAuthenticationContext as String]=context
        let status=SecItemCopyMatching(q as CFDictionary,nil)
        return status==errSecSuccess || status==errSecInteractionNotAllowed
    }
    static func save(_ value:PortalCredentials)throws {
        guard value.valid else{throw failure("请输入完整的系统账号和口令。")}
        let attrs=[kSecValueData as String:try JSONEncoder().encode(value)]
        let result=SecItemUpdate(base as CFDictionary,attrs as CFDictionary)
        if result==errSecItemNotFound {
            var item=base;attrs.forEach{item[$0.key]=$0.value}
            guard SecItemAdd(item as CFDictionary,nil)==errSecSuccess else{throw failure("系统账号保存失败，请确认钥匙串授权后重试。")}
        } else if result != errSecSuccess {throw failure("系统账号保存失败，请确认钥匙串授权后重试。")}
    }
    static func read(interactive:Bool=true)throws->PortalCredentials {
        var q=base;q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        if !interactive {
            let context=LAContext();context.interactionNotAllowed=true
            q[kSecUseAuthenticationContext as String]=context
            // Login-keychain items on older systems may ignore LAContext.
            q[kSecUseAuthenticationUI as String]=kSecUseAuthenticationUIFail
        }
        var item:CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary,&item)==errSecSuccess,let data=item as? Data,
              let value=try? JSONDecoder().decode(PortalCredentials.self,from:data),value.valid else {
            throw failure("无法读取系统账号，请确认钥匙串授权或重新设置。")
        }
        return value
    }
}
enum SafariLogin {
    // One probe or one submission only. The native recovery owner polls the
    // result, owns the child process, and cancels it on stop. No hidden loop can
    // activate Safari or submit a second login after monitoring has stopped.
    static func recoveryScript(_ credentials:PortalCredentials?)throws->String {
        let payload=try credentials.map{String(data:try JSONEncoder().encode($0),encoding:.utf8)!} ?? "null"
        return try pageScript(resource:"portal-login",argument:payload)
    }
    static func pageScript(resource:String,argument:String)throws->String {
        guard ["portal-login","portal-device"].contains(resource),let path=Bundle.main.url(forResource:resource,withExtension:"js") else{throw failure("系统连接组件缺失")}
        let function=try String(contentsOf:path,encoding:.utf8)
        return """
        try
          with timeout of 8 seconds
            tell application id "com.apple.Safari"
              return do JavaScript \(quote("("+function+")("+argument+")")) in current tab of front window
            end tell
          end timeout
        on error ignoredMessage number errorNumber
          return "EVENT_" & errorNumber
        end try
        """
    }
    // No credentials in argv, disk, clipboard, or diagnostic output.
    static func quote(_ value:String)->String {
        "\""+value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"").replacingOccurrences(of:"\r",with:"\\r").replacingOccurrences(of:"\n",with:"\\n")+"\""
    }
    static func script(_ credentials:PortalCredentials)throws->String {
        guard credentials.valid,let path=Bundle.main.url(forResource:"portal-login",withExtension:"js") else{throw failure("登录组件缺失，请重新构建应用。")}
        let function=try String(contentsOf:path,encoding:.utf8)
        let json=String(data:try JSONEncoder().encode(credentials),encoding:.utf8)!
        let probe=quote("("+function+")(null)")
        let fill=quote("("+function+")("+json+")")
        return """
        try
        with timeout of 8 seconds
          tell application id "com.apple.Safari"
            activate
            set targetTab to missing value
            set portalWindow to missing value
            repeat with candidateWindow in windows
              repeat with candidateTab in tabs of candidateWindow
                if URL of candidateTab starts with "https://portal.example.com:9978/admin.php" then
                  set targetTab to contents of candidateTab
                  set portalWindow to contents of candidateWindow
                  exit repeat
                end if
              end repeat
              if targetTab is not missing value then exit repeat
            end repeat
            if targetTab is missing value then
              make new document with properties {URL:\(quote(SystemPortal.url.absoluteString))}
              set targetTab to current tab of front window
            else
              set index of portalWindow to 1
              set current tab of portalWindow to targetTab
            end if
            if URL of targetTab does not start with \(quote(SystemPortal.url.absoluteString)) then
              set URL of targetTab to \(quote(SystemPortal.url.absoluteString))
            end if
            set current tab of front window to targetTab
            repeat 15 times
              try
                set state to do JavaScript \(probe) in targetTab
              on error ignoredMessage number errorNumber
                return "EVENT_" & errorNumber
              end try
              if state is "SIGNED_IN" then return state
              if state is "READY" then
                try
                  set resultCode to do JavaScript \(fill) in targetTab
                on error
                  return "UNCERTAIN"
                end try
                if resultCode is not "SUBMITTED" then return resultCode
                repeat 10 times
                  delay 1
                  try
                    if (do JavaScript \(probe) in targetTab) is "SIGNED_IN" then return "SIGNED_IN"
                  on error
                    return "SUBMITTED"
                  end try
                end repeat
                return "SUBMITTED"
              end if
              if state is not "WAIT" then return state
              delay 1
            end repeat
            return "TIMEOUT"
          end tell
        end timeout
        on error ignoredMessage number errorNumber
          return "EVENT_" & errorNumber
        end try
        """
    }
    static func run(_ credentials:PortalCredentials)->String {
        guard let source=try? script(credentials),let data=source.data(using:.utf8) else{return "FAILED"}
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/osascript");process.arguments=["-"]
        let input=Pipe(),output=Pipe();process.standardInput=input;process.standardOutput=output
        // AppleScript errors may quote source fragments; never retain or display stderr.
        process.standardError=FileHandle.nullDevice
        let done=DispatchSemaphore(value:0);process.terminationHandler={_ in done.signal()}
        do {
            try process.run()
            try input.fileHandleForWriting.write(contentsOf:data);try input.fileHandleForWriting.close()
        }catch{if process.isRunning{process.terminate()};return "FAILED"}
        guard done.wait(timeout:.now()+40) == .success else{if process.isRunning{process.terminate()};return "TIMEOUT"}
        guard process.terminationStatus==0 else{return "AUTOMATION_REQUIRED"}
        let code=String(data:output.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "FAILED"
        if code.range(of:"^EVENT_-?[0-9]{1,8}$",options:.regularExpression) != nil{return code}
        return ["SIGNED_IN","SUBMITTED","READY","WAIT","BLOCKED","MANUAL","AUTOMATION_REQUIRED","UNCERTAIN","TIMEOUT"].contains(code) ? code:"FAILED"
    }
    static func message(_ code:String)->String {
        switch code {
        case "SIGNED_IN":return "Safari 已登录系统，设备页面已确认。"
        case "SUBMITTED":return "已自动填写并提交一次登录；请在 Safari 查看结果，程序不会自动重试。"
        case "MANUAL":return "页面需要动态密码或验证，请在 Safari 手动完成。"
        case "BLOCKED":return "页面地址或表单不符合安全检查，未自动填写；请打开正确系统登录页。"
        case "AUTOMATION_REQUIRED":return "请允许本软件控制 Safari，并在 Safari 开发者设置中允许 Apple 事件中的 JavaScript；安全警告需本人处理。"
        case "UNCERTAIN":return "登录结果不确定，请检查 Safari；为避免重复提交，不自动重试。"
        case "TIMEOUT":return "等待登录超时，请检查 Safari 或系统授权弹窗；未自动重试。"
        default:
            if code.hasPrefix("EVENT_"){return "Safari 自动化未完成（系统错误码："+code.dropFirst(6)+"）；未自动重试，请检查授权。"}
            return "自动登录未完成，请检查 Safari，必要时手动登录。"
        }
    }
}
