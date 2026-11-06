import Darwin
import Foundation
import dnssd

@MainActor final class PairingDiscovery {
    private var ref: DNSServiceRef?
    private var failure: (() -> Void)?

    func start(route: LocalRoute, port: UInt16, onFailure: @escaping () -> Void) {
        stop()
        let interface = if_nametoindex(route.interface)
        // Never register on all interfaces when the selected network has disappeared.
        guard interface != 0, !route.address.hasPrefix("127."),
              LocalRoute.available().contains(route) else { onFailure(); return }
        failure = onFailure
        let txt = NetService.data(fromTXTRecord: ["ip": Data(route.address.utf8)])
        let result = txt.withUnsafeBytes { buffer in
            DNSServiceRegister(&ref, 0, interface, "监控机 1", "_mailmonctl._tcp", "local.", nil,
                               port.bigEndian, UInt16(buffer.count), buffer.baseAddress,
                               { ref, _, error, _, _, _, context in
                guard error != kDNSServiceErr_NoError, let context else { return }
                let discovery = Unmanaged<PairingDiscovery>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated {
                    guard discovery.ref == ref else { return }
                    discovery.failure?()
                }
            }, Unmanaged.passUnretained(self).toOpaque())
        }
        guard result == kDNSServiceErr_NoError, let ref,
              DNSServiceSetDispatchQueue(ref, .main) == kDNSServiceErr_NoError else {
            stop()
            onFailure()
            return
        }
    }

    func stop() {
        if let ref { DNSServiceRefDeallocate(ref) }
        ref = nil
        failure = nil
    }
}
