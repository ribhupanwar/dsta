import XCTest
@testable import PulseForge

final class SleepNeedCalculatorTests: XCTestCase {
    func testDoesNotInventEightHourPersonalBaseline() {
        XCTAssertNil(SleepNeedCalculator.calculate(sleepDebtHours: nil))
        XCTAssertNil(SleepNeedCalculator.calculate(sleepDebtHours: 0))
        XCTAssertNil(SleepNeedCalculator.calculate(baseNeedHours: nil, sleepDebtHours: 2))
    }

    func testUsesValidPersonalBaselineAndAddsHalfOfDebt() throws {
        let result = try XCTUnwrap(SleepNeedCalculator.calculate(.init(
            personalBaselineHours: 7.5,
            sleepDebtHours: 2,
            napMinutes: nil,
            strainAdjustmentHours: nil
        )))
        XCTAssertEqual(result.baselineHours, 7.5, accuracy: 0.001)
        XCTAssertEqual(result.debtAdjustmentHours, 1, accuracy: 0.001)
        XCTAssertEqual(result.targetHours, 8.5, accuracy: 0.001)
    }

    func testCapsDebtRepaymentNapAndStrainAdjustments() throws {
        let result = try XCTUnwrap(SleepNeedCalculator.calculate(.init(
            personalBaselineHours: 8,
            sleepDebtHours: 20,
            napMinutes: 500,
            strainAdjustmentHours: 5
        )))
        XCTAssertEqual(result.debtAdjustmentHours, 2, accuracy: 0.001)
        XCTAssertEqual(result.napAdjustmentHours, 1.5, accuracy: 0.001)
        XCTAssertEqual(result.strainAdjustmentHours, 1, accuracy: 0.001)
        XCTAssertEqual(result.targetHours, 9.5, accuracy: 0.001)
    }

    func testRejectsInvalidPersonalBaseline() {
        XCTAssertNil(SleepNeedCalculator.calculate(.init(
            personalBaselineHours: .nan,
            sleepDebtHours: 2,
            napMinutes: nil,
            strainAdjustmentHours: nil
        )))
        XCTAssertNil(SleepNeedCalculator.calculate(baseNeedHours: 4, sleepDebtHours: 0))
    }

    func testIgnoresInvalidOptionalAdjustmentsWhenBaselineExists() throws {
        let result = try XCTUnwrap(SleepNeedCalculator.calculate(.init(
            personalBaselineHours: 8,
            sleepDebtHours: .nan,
            napMinutes: -20,
            strainAdjustmentHours: .infinity
        )))
        XCTAssertEqual(result.targetHours, 8, accuracy: 0.001)
    }
}
