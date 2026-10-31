import XCTest
@testable import PulseForge

final class WhoopIMUCadenceAutocorrelationTests: XCTestCase {
    func testEstimatesPeriodicWalkingCadence() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = (0..<2000).map { index -> WhoopIMUSample in
            let t = Double(index) / 100.0
            let pulse = sin(2 * .pi * 1.8 * t)
            return WhoopIMUSample(
                timestamp: start.addingTimeInterval(t),
                accelerationXG: 0, accelerationYG: 0,
                accelerationZG: 1.0 + 0.18 * pulse,
                rotationXDPS: 0, rotationYDPS: 0, rotationZDPS: 0
            )
        }
        let estimate = WhoopIMUCadenceAutocorrelation.estimate(samples: samples)
        XCTAssertGreaterThanOrEqual(estimate, 32)
        XCTAssertLessThanOrEqual(estimate, 40)
    }

    func testRejectsStationarySignal() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = (0..<500).map { index in
            WhoopIMUSample(
                timestamp: start.addingTimeInterval(Double(index) / 100.0),
                accelerationXG: 0, accelerationYG: 0, accelerationZG: 1,
                rotationXDPS: 0, rotationYDPS: 0, rotationZDPS: 0
            )
        }
        XCTAssertEqual(WhoopIMUCadenceAutocorrelation.estimate(samples: samples), 0)
    }
}
