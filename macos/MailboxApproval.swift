import Foundation
import CryptoKit

/// Identity confirmed in the desktop monitor. A session URL can contain secrets.
struct MailboxApproval: Decodable {
    let title: String
    let bundle: String
    let approvedPage: String?

    static func read(from settings: URL) throws -> Self? {
        guard FileManager.default.fileExists(atPath: settings.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: settings))
    }

    var shareableDigest: String? {
        guard bundle == "com.apple.Safari", !title.isEmpty, let approvedPage,
              approvedPage.utf8.count == 64,
              approvedPage.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return nil }
        return approvedPage
    }

    static func identity(_ url: URL, title: String) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, !title.isEmpty else { return nil }
        let identity = Data((title + "\n" + url.absoluteString).utf8)
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }
}
