import XCTest
@testable import PulseForge

final class HistoricalWhoopPacketArchiveTests: XCTestCase {
    func testRoundTripsRawFrameAndKeepsNewestRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.json")

        func record(_ hex: String) -> HistoricalWhoopPacketRecord {
            HistoricalWhoopPacketRecord(
                receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
                channel: "FD4B0004",
                packetType: 47,
                revision: 24,
                byteCount: hex.count / 2,
                transportCRCValidated: true,
                rawFrameHex: hex,
                classification: "unclassified; raw only"
            )
        }

        XCTAssertEqual(try HistoricalWhoopPacketArchive.append(record("AA"), to: fileURL, maximumRecords: 2), 1)
        XCTAssertEqual(try HistoricalWhoopPacketArchive.append(record("BB"), to: fileURL, maximumRecords: 2), 2)
        XCTAssertEqual(try HistoricalWhoopPacketArchive.append(record("CC"), to: fileURL, maximumRecords: 2), 2)

        let loaded = HistoricalWhoopPacketArchive.load(from: fileURL)
        XCTAssertEqual(loaded.map(\.rawFrameHex), ["BB", "CC"])
        XCTAssertTrue(loaded.allSatisfy(\.transportCRCValidated))
        XCTAssertEqual(loaded.first?.revision, 24)
    }
}
