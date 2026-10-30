import XCTest
@testable import PulseForge

final class OvernightRRMetricsCalculatorTests: XCTestCase {
    private func record(at timestamp: Date,
                        intervals: [Int] = Array(repeating: 800, count: 32),
                        verified: Bool = true,
                        recordType: Int = 47,
                        revision: Int = 18) -> HistoricalRRPacketRecord {
        HistoricalRRPacketRecord(
            receivedAt: timestamp,
            recordType: recordType,
            revision: revision,
            intervalsMilliseconds: intervals,
            rawFrameHex: "fixture",
            heartRateBPM: 52,
            physiologicalTimestamp: timestamp,
            decodeError: nil,
            physiologyLayoutVerified: verified
        )
    }

    func testCalculatesOnlyWithinExplicitSleepWindowFromVerifiedType47V18() {
        let start = Date(timeIntervalSince1970: 10_000)
        let inside = record(at: start.addingTimeInterval(600))
        let outside = record(at: start.addingTimeInterval(-60))
        let result = OvernightRRMetricsCalculator.calculate(
            records: [inside, outside],
            sleepStart: start,
            sleepEnd: start.addingTimeInterval(3_600)
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.intervalCount, 32)
        XCTAssertEqual(result?.packetCount, 1)
        XCTAssertEqual(result?.rmssdMilliseconds ?? -1, 0, accuracy: 0.001)
    }

    func testRejectsUnverifiedOrWrongPacketTypes() {
        let start = Date(timeIntervalSince1970: 10_000)
        let records = [
            record(at: start, verified: false),
            record(at: start, recordType: 40),
            record(at: start, revision: 17)
        ]
        XCTAssertNil(OvernightRRMetricsCalculator.calculate(
            records: records,
            sleepStart: start.addingTimeInterval(-10),
            sleepEnd: start.addingTimeInterval(3_600)
        ))
    }

    func testRequiresMinimumRRIntervals() {
        let start = Date(timeIntervalSince1970: 10_000)
        XCTAssertNil(OvernightRRMetricsCalculator.calculate(
            records: [record(at: start, intervals: [800, 805, 798])],
            sleepStart: start.addingTimeInterval(-10),
            sleepEnd: start.addingTimeInterval(3_600)
        ))
    }

    func testRejectsPacketGapRatherThanBridgingUnknownNightSegment() {
        let start = Date(timeIntervalSince1970: 10_000)
        let records = [
            record(at: start, intervals: Array(repeating: 800, count: 16)),
            record(at: start.addingTimeInterval(121), intervals: Array(repeating: 801, count: 16))
        ]
        XCTAssertNil(OvernightRRMetricsCalculator.calculate(
            records: records,
            sleepStart: start.addingTimeInterval(-10),
            sleepEnd: start.addingTimeInterval(3_600)
        ))
    }

    func testRejectsPhysiologicallyInvalidIntervals() {
        let start = Date(timeIntervalSince1970: 10_000)
        XCTAssertNil(OvernightRRMetricsCalculator.calculate(
            records: [record(at: start, intervals: Array(repeating: 2_500, count: 32))],
            sleepStart: start.addingTimeInterval(-10),
            sleepEnd: start.addingTimeInterval(3_600)
        ))
    }

    func testRequiresValidSleepWindow() {
        let start = Date(timeIntervalSince1970: 10_000)
        XCTAssertNil(OvernightRRMetricsCalculator.calculate(
            records: [record(at: start)],
            sleepStart: start,
            sleepEnd: start
        ))
    }
}
