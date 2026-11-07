import Foundation

/// Pure state for bounded automatic reconnect attempts. A retry stays pending
/// while its backoff timer is queued, preventing late CoreBluetooth callbacks
/// from scheduling duplicate attempts. The timer marks the attempt started;
/// failure or timeout can then schedule the next backoff slot.
struct ReconnectAttemptCoordinator {
    struct ScheduledAttempt: Equatable {
        let attempt: Int
        let delay: TimeInterval
    }

    private(set) var attemptsScheduled = 0
    private(set) var retryPending = false

    mutating func scheduleNext() -> ScheduledAttempt? {
        guard !retryPending,
              let delay = ReconnectBackoffPolicy.delay(forAttempt: attemptsScheduled) else {
            return nil
        }
        attemptsScheduled += 1
        retryPending = true
        return ScheduledAttempt(attempt: attemptsScheduled, delay: delay)
    }

    /// Called immediately before CoreBluetooth.connect for the queued attempt.
    mutating func beginAttempt() {
        retryPending = false
    }

    /// A successful link resets the bounded retry sequence.
    mutating func connected() {
        attemptsScheduled = 0
        retryPending = false
    }

    /// Manual disconnect or Bluetooth unavailability cancels the retry sequence.
    mutating func stop() {
        attemptsScheduled = 0
        retryPending = false
    }
}
