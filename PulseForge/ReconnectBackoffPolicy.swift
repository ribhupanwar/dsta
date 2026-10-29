import Foundation

/// Bounded exponential reconnect schedule for a remembered WHOOP peripheral.
/// Kept pure so retry limits and delays can be verified without CoreBluetooth.
enum ReconnectBackoffPolicy {
    static let delays: [TimeInterval] = [1, 2, 4, 8, 16, 30]
    static var maximumAttempts: Int { delays.count }

    static func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 0, attempt < delays.count else { return nil }
        return delays[attempt]
    }
}
