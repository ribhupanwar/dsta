import XCTest
@testable import PulseForge

final class HistoricalRRPacketArchiveTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("historical-rr.json")
    }

    func testPersistsAndReloadsHistoricalPacketWithReceiptTimeAndRawFrame() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let record = HistoricalRRPacketRecord(
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            recordType: 47,
            revision: 18,
            intervalsMilliseconds: [602, 613],
            rawFrameHex: "AA0174",
            heartRateBPM: nil,
            physiologicalTimestamp: nil,
            decodeError: nil
        )

        XCTAssertEqual(try HistoricalRRPacketArchive.append(record, to: url), 1)
        XCTAssertEqual(HistoricalRRPacketArchive.load(from: url), [record])
    }

    func testArchiveRetainsOnlyNewestFiveHundredRecords() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        for index in 0..<(HistoricalRRPacketArchive.maximumRecords + 1) {
            let record = HistoricalRRPacketRecord(
                receivedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                recordType: 47,
                revision: 18,
                intervalsMilliseconds: [600],
                rawFrameHex: String(index),
                heartRateBPM: nil,
                physiologicalTimestamp: nil,
                decodeError: nil
            )
            _ = try HistoricalRRPacketArchive.append(record, to: url)
        }

        let records = HistoricalRRPacketArchive.load(from: url)
        XCTAssertEqual(records.count, 500)
        XCTAssertEqual(records.first?.rawFrameHex, "1")
        XCTAssertEqual(records.last?.rawFrameHex, "500")
    }

    func testPersistsValidEmptyHistoricalRRRecordWithoutDecodeError() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let record = HistoricalRRPacketRecord(
            receivedAt: Date(timeIntervalSince1970: 1_700_000_200),
            recordType: 47,
            revision: 18,
            intervalsMilliseconds: [],
            rawFrameHex: "AA0147EMPTY",
            heartRateBPM: nil,
            physiologicalTimestamp: nil,
            decodeError: nil
        )

        XCTAssertEqual(try HistoricalRRPacketArchive.append(record, to: url), 1)
        XCTAssertEqual(HistoricalRRPacketArchive.load(from: url).first, record)
    }

    func testPersistsRawFrameWhenCandidateRRLayoutIsRejected() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let record = HistoricalRRPacketRecord(
            receivedAt: Date(timeIntervalSince1970: 1_700_000_100),
            recordType: 47,
            revision: 18,
            intervalsMilliseconds: [],
            rawFrameHex: "AA0147UNDECODED",
            heartRateBPM: nil,
            physiologicalTimestamp: nil,
            decodeError: "candidate RR count/offset rejected"
        )

        XCTAssertEqual(try HistoricalRRPacketArchive.append(record, to: url), 1)
        let restored = try XCTUnwrap(HistoricalRRPacketArchive.load(from: url).first)
        XCTAssertEqual(restored.rawFrameHex, record.rawFrameHex)
        XCTAssertEqual(restored.intervalsMilliseconds, [])
        XCTAssertEqual(restored.decodeError, record.decodeError)
        XCTAssertNil(restored.physiologicalTimestamp)
    }

    func testMissingOrInvalidArchiveLoadsAsEmpty() {
        XCTAssertTrue(HistoricalRRPacketArchive.load(from: temporaryURL()).isEmpty)
    }
}
