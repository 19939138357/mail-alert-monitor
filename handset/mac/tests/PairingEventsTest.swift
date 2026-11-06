import Foundation

@main enum PairingEventTest {
    static func main() throws {
        let ip = "192.168.1.25"
        let link = "mailmonitor://pair?url=https%3A%2F%2F192.168.1.25%3A48763&pin=fixture&key=fixture"
        let offer: [String: Any] = ["url":link, "code":"000123", "expiresIn":300]
        func decode(_ input: [String: Any]) throws -> BridgeNotice {
            BridgeNotice.decode(try JSONSerialization.data(withJSONObject: input), address: ip)
        }
        guard case let .ready(value) = try decode(offer), value.code == "000123",
              value.port == 48763, value.lifetime == 300 else { fatalError("valid offer rejected") }
        let badFields: [[String: Any]] = [
            ["expiresIn":301], ["expiresIn":0], ["code":123456], ["code":"12345"], ["code":"12345A"],
            ["code":"０１２３４５"], ["url":link.replacingOccurrences(of:"192.168.1.25", with:"127.0.0.1")]
        ]
        for change in badFields {
            guard case .failure = try decode(offer.merging(change, uniquingKeysWith: { _, new in new })) else {
                fatalError("invalid offer accepted")
            }
        }
        for reason in ["paired", "attempts", "expired"] {
            guard case let .closed(value) = try decode(["event":"codeClosed", "reason":reason]), value.rawValue == reason else {
                fatalError("close reason lost")
            }
        }
        guard case .failure = try decode(["event":"codeClosed", "reason":"invalid"]) else { fatalError("bad event accepted") }
        guard case .failure = BridgeNotice.decode(Data([0,255]), address: ip) else { fatalError("bad payload accepted") }
        print("Mac 配对事件检查通过")
    }
}
