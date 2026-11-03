import XCTest
@testable import PulseForge

final class HistoricalRRPacketArchiveTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("historical-rr.json")
    }

    private func makeCRCValidType47Frame(marker: UInt8) -> [UInt8] {
        let payload: [UInt8] = [47, marker, 0x00, 0x00]
        let declaredLength = payload.count + 4
        var frame: [UInt8] = [0xAA, 0x01, UInt8(declaredLength & 0xFF),
                              UInt8((declaredLength >> 8) & 0xFF), 0x00, 0x01]
        let headerCRC = Whoop5FrameValidator.crc16Modbus(frame)
        frame.append(UInt8(headerCRC & 0xFF))
        frame.append(UInt8((headerCRC >> 8) & 0xFF))
        frame.append(contentsOf: payload)
        let payloadCRC = Whoop5FrameValidator.crc32(payload)
        frame.append(UInt8(payloadCRC & 0xFF))
        frame.append(UInt8((payloadCRC >> 8) & 0xFF))
        frame.append(UInt8((payloadCRC >> 16) & 0xFF))
        frame.append(UInt8((payloadCRC >> 24) & 0xFF))
        return frame
    }

    func testPersistsAndReloadsHistoricalPacketWithReceiptTimeAndRawFrame() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let record = HistoricalRRPacketRecord(
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            recordType: 47,
            revision: 18,
            intervalsMilliseconds: [],
            rawRRWords: [602, 613],
            rawFrameHex: "AA0174",
            heartRateBPM: nil,
            physiologicalTimestamp: nil,
            decodeError: nil
        )

        XCTAssertEqual(try HistoricalRRPacketArchive.append(record, to: url), 1)
        XCTAssertEqual(HistoricalRRPacketArchive.load(from: url), [record])
    }

    func testV18RetentionUsesReceiptTimeUntilPhysiologicalLayoutIsVerified() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let records = (0...HistoricalRRPacketArchive.maximumRecords).reversed().map { index in
            HistoricalRRPacketRecord(
                receivedAt: Date(timeIntervalSince1970: TimeInterval(HistoricalRRPacketArchive.maximumRecords - index)),
                recordType: 47, revision: 18, intervalsMilliseconds: [],
                rawRRWords: [600 + (index % 100)], rawFrameHex: String(format: "%06X", index),
                heartRateBPM: nil,
                physiologicalTimestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                decodeError: nil, physiologyLayoutVerified: false
            )
        }
        XCTAssertEqual(try HistoricalRRPacketArchive.append(contentsOf: records, to: url),
                       HistoricalRRPacketArchive.maximumRecords)
        let archived = try HistoricalRRPacketArchive.loadThrowing(from: url)
        XCTAssertEqual(archived.count, HistoricalRRPacketArchive.maximumRecords)
        XCTAssertEqual(archived.first?.rawFrameHex, String(format: "%06X", HistoricalRRPacketArchive.maximumRecords - 1))
        XCTAssertEqual(archived.last?.rawFrameHex, "000000")
        XCTAssertTrue(archived.allSatisfy { $0.physiologicalTimestamp == nil && !$0.physiologyLayoutVerified })
    }
    func testRepeatedHistoricalFrameReplayDoesNotDuplicateArchiveRecords() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let firstReceipt = Date(timeIntervalSince1970: 1_700_000_000)
        let original = HistoricalRRPacketRecord(
            receivedAt: firstReceipt,
            recordType: 47,
            revision: 18,
            intervalsMilliseconds: [],
            rawRRWords: [863],
            rawFrameHex: "AA01740001003F",
            heartRateBPM: nil,
            physiologicalTimestamp: nil,
            decodeError: nil
        )
        let replay = HistoricalRRPacketRecord(
            receivedAt: firstReceipt.addingTimeInterval(600),
            recordType: 47,
            revision: 18,
            intervalsMilliseconds: [],
            rawRRWords: [863],
            rawFrameHex: "aa01740001003f",
            heartRateBPM: nil,
            physiologicalTimestamp: nil,
            decodeError: nil
        )

        XCTAssertEqual(try HistoricalRRPacketArchive.append(original, to: url), 1)
        XCTAssertEqual(try HistoricalRRPacketArchive.append(replay, to: url), 1)

        let archived = try HistoricalRRPacketArchive.loadThrowing(from: url)
        XCTAssertEqual(archived.count, 1)
        XCTAssertEqual(archived.first?.receivedAt, firstReceipt)
        XCTAssertEqual(archived.first?.rawFrameHex, original.rawFrameHex)
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
        XCTAssertEqual(v18.count, HistoricalRRPacketArchive.maximumRecordsForOtherRevisions + 1)
        XCTAssertEqual(r21.count, HistoricalRRPacketArchive.maximumRecordsForOtherRevisions)
        XCTAssertEqual(v18.first?.rawFrameHex, "V18-0")
        XCTAssertEqual(v18.last?.rawFrameHex, "V18-500")
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

    func testLegacyRawV18FrameRemainsCandidateOnlyUntilWHOOPLayoutIsVerified() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rawFrame = "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"
        let legacy = """
        [{"receivedAt":"2026-10-30T00:00:00Z","recordType":47,"revision":18,
          "intervalsMilliseconds":[629,794],"rawRRWords":[629,794],
          "rawFrameHex":"\(rawFrame)","heartRateBPM":80,
          "physiologicalTimestamp":"2026-10-29T23:59:00Z","decodeError":null}]
        """
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: url)
        let migrated = try XCTUnwrap(HistoricalRRPacketArchive.loadThrowing(from: url).first)
        XCTAssertEqual(migrated.intervalsMilliseconds, [])
        XCTAssertEqual(migrated.rawRRWords, [602, 613])
        XCTAssertEqual(migrated.legacyUnverifiedRRValues, [629, 794])
        XCTAssertNil(migrated.heartRateBPM)
        XCTAssertNil(migrated.physiologicalTimestamp)
        XCTAssertFalse(migrated.physiologyLayoutVerified)
    }
    func testLegacyV18MillisecondsArePreservedSeparatelyFromRawWords() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let legacy = """
        [{"receivedAt":"2026-10-30T00:00:00Z","recordType":47,"revision":18,
          "intervalsMilliseconds":[629,794],"rawFrameHex":"AA01",
          "heartRateBPM":80,"physiologicalTimestamp":"2026-10-29T23:59:00Z","decodeError":null}]
        """
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: url)
        let migrated = try XCTUnwrap(HistoricalRRPacketArchive.load(from: url).first)
        XCTAssertEqual(migrated.intervalsMilliseconds, [])
        XCTAssertNil(migrated.rawRRWords)
        XCTAssertEqual(migrated.legacyUnverifiedRRValues, [629, 794])
        XCTAssertNil(migrated.heartRateBPM)
        XCTAssertNil(migrated.physiologicalTimestamp)
        let exported = try XCTUnwrap(HistoricalRRPacketArchive.exportJSON(from: url))
        let exportDecoder = JSONDecoder()
        exportDecoder.dateDecodingStrategy = .iso8601
        let exportedRecord = try XCTUnwrap(exportDecoder.decode([HistoricalRRPacketRecord].self, from: Data(exported.utf8)).first)
        XCTAssertEqual(exportedRecord.legacyUnverifiedRRValues, [629, 794])
        XCTAssertNil(exportedRecord.heartRateBPM)
        XCTAssertNil(exportedRecord.physiologicalTimestamp)
    }
    func testArchiveRecordSeparatesVerifiedMillisecondsFromRawWords() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let record = HistoricalRRPacketRecord(
            receivedAt: Date(timeIntervalSince1970: 1_700_000_300),
            recordType: 47, revision: 18, intervalsMilliseconds: [],
            rawRRWords: [629, 794], rawFrameHex: "AA01",
            heartRateBPM: nil, physiologicalTimestamp: nil, decodeError: nil
        )
        _ = try HistoricalRRPacketArchive.append(record, to: url)
        let restored = try XCTUnwrap(HistoricalRRPacketArchive.load(from: url).first)
        XCTAssertEqual(restored.intervalsMilliseconds, [])
        XCTAssertEqual(restored.rawRRWords, [629, 794])
        XCTAssertNil(restored.legacyUnverifiedRRValues)
    }

    func testPreviouslyVerifiedV18FieldsAreDowngradedUntilWHOOPLayoutIsProven() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let timestamp = Date(timeIntervalSince1970: 1_780_916_150)
        let record = HistoricalRRPacketRecord(
            receivedAt: timestamp.addingTimeInterval(3), recordType: 47, revision: 18,
            intervalsMilliseconds: [602, 613], rawRRWords: [602, 613], rawFrameHex: "AA0174",
            heartRateBPM: 102, physiologicalTimestamp: timestamp, decodeError: nil,
            physiologyLayoutVerified: true
        )
        _ = try HistoricalRRPacketArchive.append(record, to: url)
        let restored = try XCTUnwrap(HistoricalRRPacketArchive.load(from: url).first)
        XCTAssertEqual(restored.intervalsMilliseconds, [])
        XCTAssertEqual(restored.rawRRWords, [602, 613])
        XCTAssertEqual(restored.legacyUnverifiedRRValues, [602, 613])
        XCTAssertNil(restored.heartRateBPM)
        XCTAssertNil(restored.physiologicalTimestamp)
        XCTAssertFalse(restored.physiologyLayoutVerified)
    }
    func testLegacyV18FrameWithInvalidCRCDoesNotPromotePhysiology() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let validHex = "AA01740001003FB12F128037170700FA9AE36A9939004B015F030000000000000000992C074B0000FF4034793C00005CBF71FD30BEC3B5FF3E6C01F200000000000000000031013B01F90C900A010C060C10000000000000000000000000000000000000000000000100A1B724230000001A30A8C00000002AC67557"
        var frame = stride(from: 0, to: validHex.count, by: 2).map { offset -> UInt8 in
            let start = validHex.index(validHex.startIndex, offsetBy: offset)
            let end = validHex.index(start, offsetBy: 2)
            return UInt8(validHex[start..<end], radix: 16)!
        }
        frame[30] ^= 0x01 // Preserve header, invalidate the payload CRC.
        let corruptHex = frame.map { String(format: "%02X", $0) }.joined()
        let legacy = """
        [{"receivedAt":"2026-10-30T00:00:00Z","recordType":47,"revision":18,
          "intervalsMilliseconds":[863],"rawRRWords":[863],
          "rawFrameHex":"\(corruptHex)","heartRateBPM":75,
          "physiologicalTimestamp":"2026-10-29T19:14:02Z","decodeError":null}]
        """
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: url)

        let migrated = try XCTUnwrap(HistoricalRRPacketArchive.loadThrowing(from: url).first)
        XCTAssertEqual(migrated.intervalsMilliseconds, [])
        XCTAssertEqual(migrated.rawRRWords, [863])
        XCTAssertEqual(migrated.legacyUnverifiedRRValues, [863])
        XCTAssertNil(migrated.heartRateBPM)
        XCTAssertNil(migrated.physiologicalTimestamp)
        XCTAssertFalse(migrated.physiologyLayoutVerified)
    }

    func testUnmappedType47FramesAreRetainedRawWithoutR24FieldAssumptions() {
        for marker in [UInt8(9), UInt8(68)] {
            let frame = makeCRCValidType47Frame(marker: marker)
            let record = HistoricalRRPacketRecord.unmappedType47Candidate(
                frame: frame, receivedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
            XCTAssertNotNil(record)
            XCTAssertEqual(record?.recordType, 47)
            XCTAssertEqual(record?.revision, Int(marker))
            XCTAssertEqual(record?.rawFrameHex, frame.map { String(format: "%02X", $0) }.joined())
            XCTAssertEqual(record?.intervalsMilliseconds, [])
            XCTAssertNil(record?.rawRRWords)
            XCTAssertNil(record?.legacyUnverifiedRRValues)
            XCTAssertNil(record?.heartRateBPM)
            XCTAssertNil(record?.physiologicalTimestamp)
            XCTAssertFalse(record?.physiologyLayoutVerified ?? true)
        }
    }

    func testEmptyAppendDoesNotHideCorruptArchive() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try HistoricalRRPacketArchive.append(contentsOf: [], to: url))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testAppendDoesNotOverwriteCorruptExistingArchive() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: url)
        let record = HistoricalRRPacketRecord(
            receivedAt: Date(timeIntervalSince1970: 1_700_000_400),
            recordType: 47, revision: 18, intervalsMilliseconds: [],
            rawRRWords: [700], rawFrameHex: "AA01",
            heartRateBPM: nil, physiologicalTimestamp: nil, decodeError: nil
        )

        XCTAssertThrowsError(try HistoricalRRPacketArchive.append(record, to: url))
        XCTAssertNil(HistoricalRRPacketArchive.exportJSON(from: url))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testMissingArchiveLoadsAsEmpty() throws {
        let url = temporaryURL()
        XCTAssertTrue(try HistoricalRRPacketArchive.loadThrowing(from: url).isEmpty)
        XCTAssertTrue(HistoricalRRPacketArchive.load(from: url).isEmpty)
    }

    func testCorruptArchiveIsDistinguishableFromMissingArchive() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: url)

        XCTAssertThrowsError(try HistoricalRRPacketArchive.loadThrowing(from: url))
        // Preserve the historical non-throwing API for existing call sites.
        XCTAssertTrue(HistoricalRRPacketArchive.load(from: url).isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }
    func testRetentionSeparatesPacketTypesThatShareTheSameRevisionMarker() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var records: [HistoricalRRPacketRecord] = []
        for index in 0...HistoricalRRPacketArchive.maximumRecordsForOtherRevisions {
            records.append(HistoricalRRPacketRecord(
                receivedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                recordType: 40, revision: 18, intervalsMilliseconds: [],
                rawFrameHex: "TYPE40-\(index)", heartRateBPM: nil,
                physiologicalTimestamp: nil, decodeError: "candidate only"
            ))
            records.append(HistoricalRRPacketRecord(
                receivedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                recordType: 47, revision: 18, intervalsMilliseconds: [],
                rawFrameHex: "TYPE47-\(index)", heartRateBPM: nil,
                physiologicalTimestamp: nil, decodeError: "candidate only"
            ))
        }

        let retainedCount = try HistoricalRRPacketArchive.append(contentsOf: records, to: url)
        let archived = try HistoricalRRPacketArchive.loadThrowing(from: url)
        let type40 = archived.filter { $0.recordType == 40 && $0.revision == 18 }
        let type47 = archived.filter { $0.recordType == 47 && $0.revision == 18 }

        XCTAssertEqual(retainedCount, 2 * HistoricalRRPacketArchive.maximumRecordsForOtherRevisions + 1)
        XCTAssertEqual(type40.count, HistoricalRRPacketArchive.maximumRecordsForOtherRevisions)
        XCTAssertEqual(type40.first?.rawFrameHex, "TYPE40-1")
        XCTAssertEqual(type40.last?.rawFrameHex, "TYPE40-500")
        XCTAssertEqual(type47.count, HistoricalRRPacketArchive.maximumRecordsForOtherRevisions + 1)
        XCTAssertEqual(type47.first?.rawFrameHex, "TYPE47-0")
        XCTAssertEqual(type47.last?.rawFrameHex, "TYPE47-500")
    }

    
    func testLegacyEmptyArraysRecoverCandidateWordsAndPreservePriorMillisecondsAsUnverified() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rawFrame = "AA01740001003FB12F128037170700FA9AE36A9939004B015F030000000000000000992C074B0000FF4034793C00005CBF71FD30BEC3B5FF3E6C01F200000000000000000031013B01F90C900A010C060C10000000000000000000000000000000000000000000000100A1B724230000001A30A8C00000002AC67557"
        let legacy = """
        [{"receivedAt":"2026-10-30T00:00:00Z","recordType":47,"revision":18,
          "intervalsMilliseconds":[629,794],"rawRRWords":[],
          "legacyUnverifiedRRValues":[],"rawFrameHex":"\(rawFrame)",
          "heartRateBPM":80,"physiologicalTimestamp":"2026-10-29T23:59:00Z","decodeError":null}]
        """
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: url)

        let migrated = try XCTUnwrap(HistoricalRRPacketArchive.loadThrowing(from: url).first)
        XCTAssertEqual(migrated.intervalsMilliseconds, [])
        XCTAssertEqual(migrated.rawRRWords, [863])
        XCTAssertEqual(migrated.legacyUnverifiedRRValues, [629, 794])
        XCTAssertNil(migrated.heartRateBPM)
        XCTAssertNil(migrated.physiologicalTimestamp)
        XCTAssertFalse(migrated.physiologyLayoutVerified)
    }

    func testEmptyLegacyArraysNormalizeToAbsentWhenFrameCRCIsInvalid() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let validHex = "AA01740001003FB12F128037170700FA9AE36A9939004B015F030000000000000000992C074B0000FF4034793C00005CBF71FD30BEC3B5FF3E6C01F200000000000000000031013B01F90C900A010C060C10000000000000000000000000000000000000000000000100A1B724230000001A30A8C00000002AC67557"
        var frame = stride(from: 0, to: validHex.count, by: 2).map { offset -> UInt8 in
            let start = validHex.index(validHex.startIndex, offsetBy: offset)
            let end = validHex.index(start, offsetBy: 2)
            return UInt8(validHex[start..<end], radix: 16)!
        }
        frame[30] ^= 0x01
        let corruptHex = frame.map { String(format: "%02X", $0) }.joined()
        let legacy = """
        [{"receivedAt":"2026-10-30T00:00:00Z","recordType":47,"revision":18,
          "intervalsMilliseconds":[863],"rawRRWords":[],
          "legacyUnverifiedRRValues":[],"rawFrameHex":"\(corruptHex)",
          "heartRateBPM":75,"physiologicalTimestamp":"2026-10-29T19:14:02Z","decodeError":null}]
        """
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: url)

        let migrated = try XCTUnwrap(HistoricalRRPacketArchive.loadThrowing(from: url).first)
        XCTAssertEqual(migrated.intervalsMilliseconds, [])
        XCTAssertNil(migrated.rawRRWords)
        XCTAssertEqual(migrated.legacyUnverifiedRRValues, [863])
        XCTAssertNil(migrated.heartRateBPM)
        XCTAssertNil(migrated.physiologicalTimestamp)
        XCTAssertFalse(migrated.physiologyLayoutVerified)
    }

}
