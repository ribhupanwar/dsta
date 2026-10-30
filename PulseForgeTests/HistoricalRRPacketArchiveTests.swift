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

    func testV18ArchiveRetainsFullDayWindow() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let records = (0...HistoricalRRPacketArchive.maximumRecords).map { index in
            HistoricalRRPacketRecord(
                receivedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                recordType: 47,
                revision: 18,
                intervalsMilliseconds: [],
                rawRRWords: [600 + (index % 100)],
                rawFrameHex: String(index),
                heartRateBPM: nil,
                physiologicalTimestamp: nil,
                decodeError: nil
            )
        }
        XCTAssertEqual(
            try HistoricalRRPacketArchive.append(contentsOf: records, to: url),
            HistoricalRRPacketArchive.maximumRecords
        )

        let archived = HistoricalRRPacketArchive.load(from: url)
        XCTAssertEqual(archived.count, HistoricalRRPacketArchive.maximumRecords)
        XCTAssertEqual(archived.first?.rawFrameHex, "1")
        XCTAssertEqual(archived.last?.rawFrameHex, String(HistoricalRRPacketArchive.maximumRecords))
    }

    func testArchiveKeepsSeparateRetentionWindowsForEachRevision() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        for index in 0...HistoricalRRPacketArchive.maximumRecordsForOtherRevisions {
            let v18 = HistoricalRRPacketRecord(
                receivedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                recordType: 47, revision: 18, intervalsMilliseconds: [],
                rawFrameHex: "V18-\(index)", heartRateBPM: nil,
                physiologicalTimestamp: nil, decodeError: nil
            )
            let r21 = HistoricalRRPacketRecord(
                receivedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                recordType: 47, revision: 21, intervalsMilliseconds: [],
                rawFrameHex: "R21-\(index)", heartRateBPM: nil,
                physiologicalTimestamp: nil, decodeError: "R21 IMU; not RR"
            )
            _ = try HistoricalRRPacketArchive.append(contentsOf: [v18, r21], to: url)
        }

        let records = HistoricalRRPacketArchive.load(from: url)
        let v18 = records.filter { $0.revision == 18 }
        let r21 = records.filter { $0.revision == 21 }
        XCTAssertEqual(v18.count, HistoricalRRPacketArchive.maximumRecordsForOtherRevisions)
        XCTAssertEqual(r21.count, HistoricalRRPacketArchive.maximumRecordsForOtherRevisions)
        XCTAssertEqual(v18.first?.rawFrameHex, "V18-1")
        XCTAssertEqual(r21.first?.rawFrameHex, "R21-1")
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

    func testLegacyV18MillisecondsFieldMigratesToUnverifiedRawWords() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let legacy = """
        [{"receivedAt":"2026-10-30T00:00:00Z","recordType":47,"revision":18,
          "intervalsMilliseconds":[629,794],"rawFrameHex":"AA01",
          "heartRateBPM":80,"physiologicalTimestamp":null,"decodeError":null}]
        """
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: url)

        let migrated = try XCTUnwrap(HistoricalRRPacketArchive.load(from: url).first)
        XCTAssertEqual(migrated.intervalsMilliseconds, [])
        XCTAssertEqual(migrated.rawRRWords, [629, 794])
    }

    func testArchiveRecordSeparatesVerifiedMillisecondsFromRawWords() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let record = HistoricalRRPacketRecord(
            receivedAt: Date(timeIntervalSince1970: 1_700_000_300),
            recordType: 47, revision: 18, intervalsMilliseconds: [],
            rawRRWords: [629, 794], rawFrameHex: "AA01",
            heartRateBPM: 80, physiologicalTimestamp: nil, decodeError: nil
        )
        _ = try HistoricalRRPacketArchive.append(record, to: url)
        let restored = try XCTUnwrap(HistoricalRRPacketArchive.load(from: url).first)
        XCTAssertEqual(restored.intervalsMilliseconds, [])
        XCTAssertEqual(restored.rawRRWords, [629, 794])
    }

    func testMissingOrInvalidArchiveLoadsAsEmpty() {
        XCTAssertTrue(HistoricalRRPacketArchive.load(from: temporaryURL()).isEmpty)
    }
}
