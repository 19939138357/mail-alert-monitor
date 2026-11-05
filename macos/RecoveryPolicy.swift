import Foundation

/// A single recovery attempt owns its UUID until it finishes or is cancelled.
/// `attempts` counts consecutive completed failures, not scan-loop iterations.
struct ReconnectPolicy {
    private(set) var attempts = 0
    private(set) var nextAttempt = Date.distantPast
    private(set) var inFlight: UUID?

    mutating func begin(now: Date) -> UUID? {
        guard inFlight == nil, now >= nextAttempt else { return nil }
        let id = UUID()
        inFlight = id
        return id
    }

    @discardableResult
    mutating func finish(_ id: UUID, recovered: Bool, now: Date) -> Bool {
        guard inFlight == id else { return false }
        inFlight = nil
        if recovered {
            reset()
        } else {
            // Keep the diagnostic failure count while bounding retry frequency.
            if attempts < Int.max { attempts += 1 }
            let delays: [TimeInterval] = [5, 15, 30, 60]
            nextAttempt = now.addingTimeInterval(delays[min(attempts - 1, delays.count - 1)])
        }
        return true
    }

    mutating func cancel() {
        inFlight = nil
        reset()
    }

    /// Ordinary healthy scans may clear backoff only outside an owned attempt.
    /// An in-flight recovery must finish through its UUID and stronger checks.
    mutating func healthy() {
        guard inFlight == nil else { return }
        reset()
    }

    private mutating func reset() {
        attempts = 0
        nextAttempt = .distantPast
    }

    /// A label alone grants no permission to click: the caller must also verify
    /// the accessible button, original remote origin and disconnection overlay.
    static func isReconnectButtonLabel(_ label: String) -> Bool {
        let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == "重新连接" || value == "重连" || value.lowercased() == "reconnect"
    }
}

enum RecoveryPolicyTests {
    static func run() throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else {
                throw NSError(domain: "RecoveryPolicyTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1
        }

        let start = Date(timeIntervalSince1970: 1_000)
        var policy = ReconnectPolicy()
        try check(policy.attempts == 0 && policy.inFlight == nil && policy.nextAttempt == .distantPast,
                  "recovery begins idle without backoff")
        let first = policy.begin(now: start)!
        try check(policy.inFlight == first && policy.attempts == 0,
                  "starting an attempt does not count a failure")
        try check(policy.begin(now: start.addingTimeInterval(100)) == nil,
                  "an outstanding attempt prevents another even after elapsed time")

        let unrelated = UUID()
        try check(!policy.finish(unrelated, recovered: true, now: start),
                  "an unrelated result cannot complete an attempt")
        try check(policy.inFlight == first && policy.attempts == 0,
                  "an unrelated result cannot change attempt ownership or counters")
        policy.healthy()
        try check(policy.inFlight == first,
                  "ordinary health observations cannot release an in-flight attempt")
        try check(policy.finish(first, recovered: false, now: start),
                  "the owning attempt can report a failure")
        try check(policy.inFlight == nil && policy.attempts == 1 && policy.nextAttempt == start.addingTimeInterval(5),
                  "first failure releases ownership and waits five seconds")
        try check(!policy.finish(first, recovered: true, now: start.addingTimeInterval(1)) && policy.attempts == 1,
                  "a completed attempt cannot later erase failure backoff")

        var failureTime = start
        for (index, delay) in [5.0, 15.0, 30.0, 60.0, 60.0].enumerated() {
            let deadline = failureTime.addingTimeInterval(delay)
            try check(policy.nextAttempt == deadline,
                      "failure \(index + 1) has the expected retry deadline")
            try check(policy.begin(now: deadline.addingTimeInterval(-0.001)) == nil,
                      "failure \(index + 1) cannot retry just before its deadline")
            let id = policy.begin(now: deadline)!
            try check(policy.inFlight == id,
                      "failure \(index + 1) allows retry exactly at its deadline")
            try check(policy.begin(now: deadline.addingTimeInterval(60)) == nil,
                      "retry \(index + 1) remains single-flight")
            failureTime = deadline.addingTimeInterval(2)
            try check(policy.finish(id, recovered: false, now: failureTime),
                      "retry \(index + 1) can finish with a failure")
            try check(policy.attempts == index + 2,
                      "consecutive failures are counted independently of capped delay")
        }
        try check(policy.nextAttempt == failureTime.addingTimeInterval(60),
                  "backoff remains capped at sixty seconds after repeated failures")

        let beforeLate = policy.nextAttempt
        try check(!policy.finish(first, recovered: true, now: beforeLate) && policy.nextAttempt == beforeLate,
                  "an old result cannot clear a later attempt's backoff")
        let success = policy.begin(now: beforeLate)!
        policy.healthy()
        try check(policy.inFlight == success && policy.attempts == 6 && policy.nextAttempt == beforeLate,
                  "health during recovery preserves its owner and existing failure history")
        try check(policy.finish(success, recovered: true, now: beforeLate.addingTimeInterval(3)),
                  "verified recovery completes its owning attempt")
        try check(policy.attempts == 0 && policy.inFlight == nil && policy.nextAttempt == .distantPast,
                  "verified recovery resets failures and delay")
        let afterSuccess = policy.begin(now: beforeLate.addingTimeInterval(3))!
        _ = policy.finish(afterSuccess, recovered: false, now: beforeLate.addingTimeInterval(4))
        try check(policy.attempts == 1 && policy.nextAttempt == beforeLate.addingTimeInterval(9),
                  "failure after recovery starts again with five-second delay")

        policy.healthy()
        try check(policy.attempts == 0 && policy.nextAttempt == .distantPast && policy.inFlight == nil,
                  "a healthy idle scan clears failure backoff")
        let cancelled = policy.begin(now: start)!
        policy.cancel()
        try check(policy.inFlight == nil && policy.attempts == 0 && policy.nextAttempt == .distantPast,
                  "cancellation resets the policy and releases its owner")
        try check(!policy.finish(cancelled, recovered: false, now: start),
                  "a cancelled failure cannot schedule a retry")
        let replacement = policy.begin(now: start)!
        try check(replacement != cancelled,
                  "a new monitoring session receives a different recovery identity")
        try check(!policy.finish(cancelled, recovered: true, now: start) && policy.inFlight == replacement,
                  "a cancelled success cannot complete a replacement attempt")
        _ = policy.finish(replacement, recovered: false, now: start)
        policy.cancel()
        try check(policy.attempts == 0 && policy.nextAttempt == .distantPast,
                  "cancellation also clears an already scheduled failure backoff")
        let immediate = policy.begin(now: start)!
        try check(policy.inFlight == immediate,
                  "a new monitoring session can start without the old session's delay")
        policy.cancel()
        policy.cancel()
        try check(policy.inFlight == nil && policy.attempts == 0 && policy.nextAttempt == .distantPast,
                  "repeated cancellation remains idle")

        for label in ["Reconnect", "RECONNECT", "reconnect", "重新连接", "重连", "  Reconnect\n"] {
            try check(ReconnectPolicy.isReconnectButtonLabel(label),
                      "an exact supported reconnect button label is recognized")
        }
        for label in ["", "连接", "Connect", "重新连接邮件服务器", "邮件主题：Reconnect", "Reconnect to another device", "Disconnect", "Re connect", "重新 连接"] {
            try check(!ReconnectPolicy.isReconnectButtonLabel(label),
                      "ordinary text or an ambiguous connection label is rejected")
        }
        return checks
    }
}
