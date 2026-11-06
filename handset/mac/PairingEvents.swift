import Foundation

enum OfferCloseReason: String, Decodable {
    case paired, attempts, expired

    var message: String {
        switch self {
        case .paired: return "六位码已使用。"
        case .attempts: return "此次配对尝试已用完，请获取新码。"
        case .expired: return "六位码已过期，请获取新码。"
        }
    }
}

struct CodeOffer {
    let code: String
    let lifetime: Int
    let link: String
    let port: UInt16
}

enum BridgeNotice {
    case ready(CodeOffer)
    case closed(OfferCloseReason)
    case failure(String)

    static func decode(_ line: Data, address: String) -> BridgeNotice {
        guard let values = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return .failure("配对服务响应异常，请重新开启。")
        }
        if let error = values["error"] as? String { return .failure(error) }
        if values["event"] as? String == "codeClosed", let value = values["reason"] as? String,
           let reason = OfferCloseReason(rawValue: value) { return .closed(reason) }
        guard let code = values["code"] as? String,
              code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }),
              let seconds = values["expiresIn"] as? Int, (1...300).contains(seconds),
              let link = values["url"] as? String, let pair = URLComponents(string: link),
              pair.scheme == "mailmonitor", pair.host == "pair",
              let raw = pair.queryItems?.first(where: { $0.name == "url" })?.value,
              let target = URLComponents(string: raw), target.scheme == "https", target.host == address,
              let number = target.port, let port = UInt16(exactly: number), port != 0 else {
            return .failure("电脑端未能生成有效的配对码，请重新开启。")
        }
        return .ready(CodeOffer(code: code, lifetime: seconds, link: link, port: port))
    }
}
