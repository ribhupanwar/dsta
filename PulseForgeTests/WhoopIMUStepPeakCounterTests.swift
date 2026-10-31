import XCTest
@testable import PulseForge

final class WhoopIMUStepPeakCounterTests: XCTestCase {
    func testCountsSeparatedSyntheticWristMotionPeaks() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = (0..<500).map { index -> WhoopIMUSample in
            let t = Double(index) / 100.0
            let pulse = max(0, sin(2 * .pi * 1.8 * t))
            return WhoopIMUSample(
                timestamp: start.addingTimeInterval(t),
                accelerationXG: 0,
                accelerationYG: 0,
                accelerationZG: 1.0 + 0.22 * pulse,
                rotationXDPS: 0, rotationYDPS: 0, rotationZDPS: 0
            )
        }
        let count = WhoopIMUStepPeakCounter.estimate(samples: samples)
        XCTAssertGreaterThanOrEqual(count, 7)
        XCTAssertLessThanOrEqual(count, 11)
    }

    func testReturnsZeroWithoutEnoughSamples() {
        XCTAssertEqual(WhoopIMUStepPeakCounter.estimate(samples: []), 0)
    }
}
