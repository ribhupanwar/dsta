import XCTest
@testable import PulseForge

final class RecoveryScoreCalculatorTests: XCTestCase {
    func testRequiresThreePriorDailyBaselineValues() {
        XCTAssertNil(RecoveryScoreCalculator.calculate(
            currentHRV: 55, currentRestingHeartRate: 50,
            baselineHRV: [50, 52], baselineRestingHeartRate: [52, 51]
        ))
    }

    func testUsesMedianBaselineAndWeightedComponents() throws {
        let result = try XCTUnwrap(RecoveryScoreCalculator.calculate(
            currentHRV: 60, currentRestingHeartRate: 48,
            baselineHRV: [50, 52, 200],
            baselineRestingHeartRate: [52, 50, 90]
        ))
        XCTAssertEqual(result.hrvBaseline, 52, accuracy: 0.0001)
        XCTAssertEqual(result.restingHeartRateBaseline, 52, accuracy: 0.0001)
        XCTAssertEqual(result.score, 73)
    }

    func testRejectsNonFiniteOrNonPositiveMeasurements() {
        XCTAssertNil(RecoveryScoreCalculator.calculate(
            currentHRV: .nan, currentRestingHeartRate: 50,
            baselineHRV: [50, 51, 52], baselineRestingHeartRate: [50, 51, 52]
        ))
    }

    func testScoreIsClampedToZeroThroughOneHundred() throws {
        let low = try XCTUnwrap(RecoveryScoreCalculator.calculate(
            currentHRV: 1, currentRestingHeartRate: 100,
            baselineHRV: [60, 61, 62], baselineRestingHeartRate: [50, 51, 52]
        ))
        XCTAssertEqual(low.score, 0)
    }
}
