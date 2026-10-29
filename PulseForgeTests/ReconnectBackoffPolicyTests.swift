import XCTest
@testable import PulseForge

final class ReconnectBackoffPolicyTests: XCTestCase {
    func testUsesExpectedBoundedExponentialSchedule() {
        XCTAssertEqual(
            (0..<ReconnectBackoffPolicy.maximumAttempts).compactMap {
                ReconnectBackoffPolicy.delay(forAttempt: $0)
            },
            [1, 2, 4, 8, 16, 30]
        )
    }

    func testRejectsNegativeAttempt() {
        XCTAssertNil(ReconnectBackoffPolicy.delay(forAttempt: -1))
    }

    func testStopsAfterMaximumAttempts() {
        XCTAssertNil(ReconnectBackoffPolicy.delay(forAttempt: ReconnectBackoffPolicy.maximumAttempts))
        XCTAssertNil(ReconnectBackoffPolicy.delay(forAttempt: ReconnectBackoffPolicy.maximumAttempts + 1))
    }

    func testMaximumAttemptsMatchesScheduleLength() {
        XCTAssertEqual(ReconnectBackoffPolicy.maximumAttempts, ReconnectBackoffPolicy.delays.count)
    }
}
