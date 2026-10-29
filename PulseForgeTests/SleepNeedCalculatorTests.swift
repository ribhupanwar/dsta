import XCTest
@testable import PulseForge

final class SleepNeedCalculatorTests: XCTestCase {
    func testUsesEightHourBaseWhenDebtIsUnavailableOrZero() {
        XCTAssertEqual(SleepNeedCalculator.calculate(sleepDebtHours: nil), 8, accuracy: 0.001)
        XCTAssertEqual(SleepNeedCalculator.calculate(sleepDebtHours: 0), 8, accuracy: 0.001)
    }

    func testAddsHalfOfAccumulatedDebtToTonightTarget() {
        XCTAssertEqual(SleepNeedCalculator.calculate(sleepDebtHours: 2), 9, accuracy: 0.001)
    }

    func testCapsSingleNightDebtRepaymentAtTwoHours() {
        XCTAssertEqual(SleepNeedCalculator.calculate(sleepDebtHours: 10), 10, accuracy: 0.001)
    }

    func testIgnoresInvalidDebtAndRejectsInvalidBaseSafely() {
        XCTAssertEqual(SleepNeedCalculator.calculate(sleepDebtHours: .nan), 8, accuracy: 0.001)
        XCTAssertEqual(SleepNeedCalculator.calculate(sleepDebtHours: -3), 8, accuracy: 0.001)
        XCTAssertEqual(SleepNeedCalculator.calculate(baseNeedHours: .nan, sleepDebtHours: 2), 8, accuracy: 0.001)
    }
}
