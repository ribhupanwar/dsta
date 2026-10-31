import XCTest
@testable import PulseForge

final class WhoopIMUGyroStepCounterTests: XCTestCase {
    func testCountsSeparatedSyntheticGyroscopeSwingPeaks() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = (0..<500).map { index -> WhoopIMUSample in
            let t = Double(index) / 100.0
            let pulse = max(0, sin(2 * .pi * 1.8 * t))
            return WhoopIMUSample(
                timestamp: start.addingTimeInterval(t),
                accelerationXG: 0, accelerationYG: 0, accelerationZG: 1,
                rotationXDPS: 0, rotationYDPS: 0, rotationZDPS: 42 * pulse
            )
        }
        let count = WhoopIMUGyroStepCounter.estimate(samples: samples)
        XCTAssertGreaterThanOrEqual(count, 7)
        XCTAssertLessThanOrEqual(count, 11)
    }

    func testReturnsZeroWithoutEnoughSamples() {
        XCTAssertEqual(WhoopIMUGyroStepCounter.estimate(samples: []), 0)
    }
}
