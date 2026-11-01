import XCTest
@testable import PulseForge

final class ReconnectAttemptCoordinatorTests: XCTestCase {
    func testSchedulesBackoffAndRejectsDuplicatePendingRetry() {
        var coordinator = ReconnectAttemptCoordinator()
        XCTAssertEqual(coordinator.scheduleNext(), .init(attempt: 1, delay: 1))
        XCTAssertTrue(coordinator.retryPending)
        XCTAssertNil(coordinator.scheduleNext())

        coordinator.beginAttempt()
        XCTAssertFalse(coordinator.retryPending)
        XCTAssertEqual(coordinator.scheduleNext(), .init(attempt: 2, delay: 2))
    }

    func testTimedOutAttemptCanScheduleTheNextBackoffSlot() {
        var coordinator = ReconnectAttemptCoordinator()
        _ = coordinator.scheduleNext()
        coordinator.beginAttempt()

        let retry = coordinator.scheduleNext()
        XCTAssertEqual(retry?.attempt, 2)
        XCTAssertEqual(retry?.delay, 2)
    }

    func testSuccessfulConnectionResetsBackoffSequence() {
        var coordinator = ReconnectAttemptCoordinator()
        _ = coordinator.scheduleNext()
        coordinator.beginAttempt()
        _ = coordinator.scheduleNext()

        coordinator.connected()
        XCTAssertEqual(coordinator.attemptsScheduled, 0)
        XCTAssertFalse(coordinator.retryPending)
        XCTAssertEqual(coordinator.scheduleNext(), .init(attempt: 1, delay: 1))
    }

    func testStopCancelsPendingRetryAndResetsSequence() {
        var coordinator = ReconnectAttemptCoordinator()
        _ = coordinator.scheduleNext()
        coordinator.stop()

        XCTAssertEqual(coordinator.attemptsScheduled, 0)
        XCTAssertFalse(coordinator.retryPending)
        XCTAssertEqual(coordinator.scheduleNext(), .init(attempt: 1, delay: 1))
    }

    func testStopsAfterConfiguredMaximumAttempts() {
        var coordinator = ReconnectAttemptCoordinator()
        for attempt in 1...ReconnectBackoffPolicy.maximumAttempts {
            XCTAssertEqual(coordinator.scheduleNext()?.attempt, attempt)
            coordinator.beginAttempt()
        }
        XCTAssertNil(coordinator.scheduleNext())
        XCTAssertEqual(coordinator.attemptsScheduled, ReconnectBackoffPolicy.maximumAttempts)
    }
}
