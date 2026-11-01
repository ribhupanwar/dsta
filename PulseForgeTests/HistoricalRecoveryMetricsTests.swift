import XCTest
@testable import PulseForge

final class HistoricalRecoveryMetricsTests: XCTestCase {
    private func record(second: TimeInterval, rr: [Int] = [800, 810],
                        hr: Int? = 50, error: String? = nil) -> HistoricalRRPacketRecord {
        HistoricalRRPacketRecord(
            receivedAt: Date(timeIntervalSince1970: second + 10_000),
            recordType: 47,
            revision: 18,
            intervalsMilliseconds: rr,
            heartRateBpm: hr,
            sleepStateRaw: nil,
            rawFrameHex: "AA",
            physiologicalTimestamp: Date(timeIntervalSince1970: second),
            decodeError: error
        )
    }

    func testCalculatesRMSSDFromContinuousHistoricalRRWindows() {
        let records = (0..<40).map { record(second: Double($0)) }
        let result = HistoricalRecoveryMetrics.calculate(from: records)
        XCTAssertEqual(result.qualifyingHRVWindows, 1)
        XCTAssertEqual(result.overnightRMSSDMilliseconds ?? -1, 10, accuracy: 0.0001)
    }

    func testDoesNotBridgeMissingSecondOrEmptyRRRecord() {
        var records = (0..<14).map { record(second: Double($0)) }
        records += (15..<29).map { record(second: Double($0)) }
        let result = HistoricalRecoveryMetrics.calculate(from: records)
        XCTAssertEqual(result.qualifyingHRVWindows, 0)
        XCTAssertNil(result.overnightRMSSDMilliseconds)
    }

    func testRejectsMalformedAndDuplicatePhysiologicalRecords() {
        let records = [
            record(second: 1),
            record(second: 1),
            record(second: 2, error: "bad crc")
        ]
        let result = HistoricalRecoveryMetrics.calculate(from: records)
        XCTAssertEqual(result.acceptedRRIntervals, 2)
        XCTAssertNil(result.overnightRMSSDMilliseconds)
    }

    func testRejectsRRArtifactAndReportsIt() {
        var records = (0..<40).map { record(second: Double($0), rr: [800, 810]) }
        records[10] = record(second: 10, rr: [800, 1500])
        let result = HistoricalRecoveryMetrics.calculate(from: records)
        XCTAssertGreaterThan(result.rejectedRRIntervals, 0)
    }

    func testRHRUsesLowestCoveredThirtyMinuteMeanAndIgnoresZeroSentinel() {
        let records = (0...3600).map { second in
            record(second: Double(second), rr: [], hr: second < 900 ? 55 : 48)
        }
        let result = HistoricalRecoveryMetrics.calculate(from: records)
        XCTAssertEqual(result.restingHeartRateBPM ?? -1, 48, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(result.restingHeartRateWindowCoverage, 0.80)
    }

    func testRHRRequiresMinimumThirtyMinuteCoverage() {
        let records = (0..<1000).map { record(second: Double($0), rr: [], hr: 50) }
        let result = HistoricalRecoveryMetrics.calculate(from: records)
        XCTAssertNil(result.restingHeartRateBPM)
    }

    func testNoPhysiologicalTimestampMeansNoMetric() {
        let value = HistoricalRRPacketRecord(
            receivedAt: Date(), recordType: 47, revision: 18,
            intervalsMilliseconds: [800, 810], heartRateBpm: 50,
            sleepStateRaw: nil, rawFrameHex: "AA",
            physiologicalTimestamp: nil, decodeError: nil
        )
        let result = HistoricalRecoveryMetrics.calculate(from: [value])
        XCTAssertNil(result.overnightRMSSDMilliseconds)
        XCTAssertNil(result.restingHeartRateBPM)
    }
}
