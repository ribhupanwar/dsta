import XCTest
@testable import PulseForge

final class GPSRunMetricsTests: XCTestCase {
    func testAveragePaceUsesRecordedDistanceAndDuration() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let record = GPSRunRecord(
            id: UUID(),
            startedAt: start,
            endedAt: start.addingTimeInterval(1_800),
            durationSeconds: 1_800,
            distanceMeters: 5_000,
            splits: [],
            route: []
        )

        XCTAssertEqual(record.averagePaceSecondsPerKm, 360, accuracy: 0.001)
    }

    func testAveragePaceIsZeroWhenDistanceIsZero() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let record = GPSRunRecord(
            id: UUID(),
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            durationSeconds: 600,
            distanceMeters: 0,
            splits: [],
            route: []
        )

        XCTAssertEqual(record.averagePaceSecondsPerKm, 0, accuracy: 0.001)
    }

    func testKilometreSplitPaceMatchesSplitDuration() {
        let split = GPSRunSplit(kilometre: 1, durationSeconds: 347)

        XCTAssertEqual(split.paceSecondsPerKm, 347, accuracy: 0.001)
        XCTAssertEqual(split.kilometre, 1)
    }

    func testGPSPointRoundTripsThroughCodable() throws {
        let point = GPSRunPoint(
            CLLocation(latitude: 19.0760, longitude: 72.8777)
        )
        let encoded = try JSONEncoder().encode(point)
        let decoded = try JSONDecoder().decode(GPSRunPoint.self, from: encoded)

        XCTAssertEqual(decoded.latitude, point.latitude, accuracy: 0.000001)
        XCTAssertEqual(decoded.longitude, point.longitude, accuracy: 0.000001)
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970,
                       point.timestamp.timeIntervalSince1970, accuracy: 0.001)
    }
}
