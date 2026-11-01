import XCTest
@testable import PulseForge

final class HistoricalRRPacketArchiveTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("historical-rr.jsonl")
    }

    private func record(_ index: Int) -> HistoricalRRPacketRecord {
        HistoricalRRPacketRecord(
            receivedAt: Date(timeIntervalSince1970: TimeInterval(index)),
            recordType: 47,
            revision: 18,
            intervalsMilliseconds: [602, 613],
            rawFrameHex: String(index),
            physiologicalTimestamp: Date(timeIntervalSince1970: TimeInterval(index)),
            decodeError: nil
        )
    }

    func testPersistsAndReloadsHistoricalPacketAsJSONLines() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = record(1)
        let second = record(2)

        XCTAssertEqual(try HistoricalRRPacketArchive.append(first, to: url), 1)
        XCTAssertEqual(try HistoricalRRPacketArchive.append(second, to: url), 2)
        XCTAssertEqual(HistoricalRRPacketArchive.load(from: url), [first, second])
    }

    func testAppendOnlyArchiveDoesNotTruncateAtPreviousFiveHundredRecordLimit() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        for index in 0...500 {
            _ = try HistoricalRRPacketArchive.append(record(index), to: url)
        }

        let records = HistoricalRRPacketArchive.load(from: url)
        XCTAssertEqual(records.count, 501)
        XCTAssertEqual(records.first?.rawFrameHex, "0")
        XCTAssertEqual(records.last?.rawFrameHex, "500")
    }

    func testMigratesLegacyJSONArrayBeforeAppending() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let legacy = try JSONEncoder().encode([record(10)])
        try legacy.write(to: url)

        XCTAssertEqual(try HistoricalRRPacketArchive.append(record(11), to: url), 2)
        XCTAssertEqual(HistoricalRRPacketArchive.load(from: url), [record(10), record(11)])
    }

    func testPersistsRawFrameWhenCandidateRRLayoutIsRejected() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rejected = HistoricalRRPacketRecord(
            receivedAt: Date(timeIntervalSince1970: 1_700_000_100),
            recordType: 47,
            revision: 18,
            intervalsMilliseconds: [],
            rawFrameHex: "AA0147UNDECODED",
            physiologicalTimestamp: nil,
            decodeError: "candidate v18 layout rejected"
        )

        _ = try HistoricalRRPacketArchive.append(rejected, to: url)
        let restored = try XCTUnwrap(HistoricalRRPacketArchive.load(from: url).first)
        XCTAssertEqual(restored.rawFrameHex, rejected.rawFrameHex)
        XCTAssertEqual(restored.intervalsMilliseconds, [])
        XCTAssertEqual(restored.decodeError, rejected.decodeError)
        XCTAssertNil(restored.physiologicalTimestamp)
    }

    func testMissingOrInvalidArchiveLoadsAsEmpty() {
        XCTAssertTrue(HistoricalRRPacketArchive.load(from: temporaryURL()).isEmpty)
    }
}
