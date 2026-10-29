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

    func testCapsDebtRepaymentAtTwoHours() {
        XCTAssertEqual(SleepNeedCalculator.calculate(sleepDebtHours: 10), 10, accuracy: 0.001)
    }

    func testUsesValidPersonalBaselineInsteadOfFixedEightHours() {
        let result = SleepNeedCalculator.calculate(.init(
            personalBaselineHours: 7.5,
            sleepDebtHours: 0,
            napMinutes: nil,
            strainAdjustmentHours: nil
        ))
        XCTAssertEqual(result.targetHours, 7.5, accuracy: 0.001)
        XCTAssertEqual(result.baselineHours, 7.5, accuracy: 0.001)
    }

    func testNapReducesTargetAndStrainCanIncreaseIt() {
        let result = SleepNeedCalculator.calculate(.init(
            personalBaselineHours: 8,
            sleepDebtHours: 2,
            napMinutes: 30,
            strainAdjustmentHours: 0.5
        ))
        XCTAssertEqual(result.debtAdjustmentHours, 1, accuracy: 0.001)
        XCTAssertEqual(result.napAdjustmentHours, 0.5, accuracy: 0.001)
        XCTAssertEqual(result.strainAdjustmentHours, 0.5, accuracy: 0.001)
        XCTAssertEqual(result.targetHours, 9, accuracy: 0.001)
    }

    func testCapsOptionalAdjustmentsAndRejectsInvalidValues() {
        let capped = SleepNeedCalculator.calculate(.init(
            personalBaselineHours: 8,
            sleepDebtHours: 20,
            napMinutes: 500,
            strainAdjustmentHours: 5
        ))
        XCTAssertEqual(capped.debtAdjustmentHours, 2, accuracy: 0.001)
        XCTAssertEqual(capped.napAdjustmentHours, 1.5, accuracy: 0.001)
        XCTAssertEqual(capped.strainAdjustmentHours, 1, accuracy: 0.001)
        XCTAssertEqual(capped.targetHours, 9.5, accuracy: 0.001)

        let invalid = SleepNeedCalculator.calculate(.init(
            personalBaselineHours: .nan,
            sleepDebtHours: .nan,
            napMinutes: -20,
            strainAdjustmentHours: .infinity
        ))
        XCTAssertEqual(invalid.targetHours, 8, accuracy: 0.001)
    }
}
