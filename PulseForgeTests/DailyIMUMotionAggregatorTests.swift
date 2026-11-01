import XCTest
@testable import PulseForge

final class DailyIMUMotionAggregatorTests: XCTestCase {
    private func sample(_ seconds: TimeInterval, x: Double, y: Double = 0, z: Double = 1) -> WhoopIMUSample {
        WhoopIMUSample(
            timestamp: Date(timeIntervalSince1970: seconds),
            accelerationXG: x, accelerationYG: y, accelerationZG: z,
            rotationXDPS: 0, rotationYDPS: 0, rotationZDPS: 0
        )
    }

    func testConstantAccelerationHasZeroVariation() {
        let result = DailyIMUMotionAggregator.aggregate([
            sample(1_800_000_000, x: 0),
            sample(1_800_000_000.01, x: 0),
            sample(1_800_000_000.02, x: 0)
        ], calendar: Calendar(identifier: .gregorian))

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].sampleCount, 3)
        XCTAssertEqual(result[0].motionIntensity, 0, accuracy: 0.000001)
        XCTAssertEqual(result[0].coveredSeconds, 0.02, accuracy: 0.000001)
        XCTAssertEqual(result[0].gapCount, 0)
    }

    func testAccelerationChangesAccumulateVectorVariation() {
        let result = DailyIMUMotionAggregator.aggregate([
            sample(1_800_000_000, x: 0),
            sample(1_800_000_000.01, x: 1),
            sample(1_800_000_000.02, x: 2)
        ], calendar: Calendar(identifier: .gregorian))

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].motionIntensity, 2, accuracy: 0.000001)
    }

    func testLargeGapIsReportedAndNotBridged() {
        let result = DailyIMUMotionAggregator.aggregate([
            sample(1_800_000_000, x: 0),
            sample(1_800_000_000.01, x: 1),
            sample(1_800_000_001, x: 100)
        ], calendar: Calendar(identifier: .gregorian))

        XCTAssertEqual(result[0].gapCount, 1)
        XCTAssertEqual(result[0].maximumGapSeconds, 0.99, accuracy: 0.000001)
        XCTAssertEqual(result[0].motionIntensity, 1, accuracy: 0.000001)
        XCTAssertEqual(result[0].coveredSeconds, 0.01, accuracy: 0.000001)
    }

    func testUnsortedSamplesAreSortedBeforeAggregation() {
        let result = DailyIMUMotionAggregator.aggregate([
            sample(1_800_000_000.02, x: 2),
            sample(1_800_000_000, x: 0),
            sample(1_800_000_000.01, x: 1)
        ], calendar: Calendar(identifier: .gregorian))

        XCTAssertEqual(result[0].motionIntensity, 2, accuracy: 0.000001)
        XCTAssertEqual(result[0].sampleCount, 3)
    }
}
