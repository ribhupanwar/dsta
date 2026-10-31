import XCTest
@testable import PulseForge

final class OvernightRRMetricsCalculatorTests: XCTestCase {
    private func record(at timestamp: Date,
                        intervals: [Int] = (0..<32).map { $0.isMultiple(of: 2) ? 800 : 810 },
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
        XCTAssertEqual(result?.rmssdMilliseconds ?? -1, 10, accuracy: 0.001)
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

    func testDoesNotCreateSyntheticRRDifferenceAcrossPacketBoundary() {
        let start = Date(timeIntervalSince1970: 20_000)
        let first = record(at: start, intervals: (0..<16).map { $0.isMultiple(of: 2) ? 800 : 810 })
        let second = record(at: start.addingTimeInterval(1),
                            intervals: (0..<16).map { $0.isMultiple(of: 2) ? 1000 : 1010 })
        let result = OvernightRRMetricsCalculator.calculate(
            records: [first, second],
            sleepStart: start.addingTimeInterval(-1),
            sleepEnd: start.addingTimeInterval(60)
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.intervalCount, 32)
        XCTAssertEqual(result?.differenceCount, 30)
        XCTAssertEqual(result?.packetCount, 2)
        XCTAssertEqual(result?.rmssdMilliseconds ?? -1, 10, accuracy: 0.001)
    }

    func testDeduplicatesRepeatedPhysiologicalTimestamp() {
        let start = Date(timeIntervalSince1970: 30_000)
        let sample = record(at: start)
        let duplicate = record(at: start)
        let result = OvernightRRMetricsCalculator.calculate(
            records: [sample, duplicate],
            sleepStart: start.addingTimeInterval(-1),
            sleepEnd: start.addingTimeInterval(60)
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.intervalCount, 32)
        XCTAssertEqual(result?.differenceCount, 31)
        XCTAssertEqual(result?.packetCount, 1)
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
