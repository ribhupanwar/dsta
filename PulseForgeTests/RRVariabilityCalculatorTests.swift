import XCTest
@testable import PulseForge

final class RRVariabilityCalculatorTests: XCTestCase {
    func testRequiresAtLeastThirtyIntervals() {
        XCTAssertNil(RRVariabilityCalculator.rmssdMilliseconds(from: Array(repeating: 600, count: 29)))
    }

    func testConstantIntervalsProduceZeroRMSSD() {
        XCTAssertEqual(RRVariabilityCalculator.rmssdMilliseconds(from: Array(repeating: 600, count: 30)), 0)
    }

    func testCalculatesRMSSDFromSuccessiveDifferences() {
        let intervals = Array(repeating: [600, 610], count: 15).flatMap { $0 }
        XCTAssertEqual(RRVariabilityCalculator.rmssdMilliseconds(from: intervals) ?? -1, 10, accuracy: 0.0001)
    }

    func testRejectsPhysiologicallyInvalidIntervals() {
        var intervals = Array(repeating: 600, count: 30)
        intervals[12] = 0
        XCTAssertNil(RRVariabilityCalculator.rmssdMilliseconds(from: intervals))
    }
}
