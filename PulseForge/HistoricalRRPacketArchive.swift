import Foundation

/// Durable forensic archive for CRC-valid historical RR frames.
/// receivedAt is the phone's receipt time, NOT the physiological sample time.
/// Do not use these records for overnight HRV until the packet's embedded
/// timestamp/layout has been independently verified.
struct HistoricalRRPacketRecord: Codable, Equatable {
    let receivedAt: Date
    let recordType: Int
    let revision: Int
    let intervalsMilliseconds: [Int]
    let rawFrameHex: String
}

enum HistoricalRRPacketArchive {
    static let maximumRecords = 500

    static func load(from fileURL: URL) -> [HistoricalRRPacketRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode([HistoricalRRPacketRecord].self, from: data) else {
            return []
        }
        return records
    }

    @discardableResult
    static func append(_ record: HistoricalRRPacketRecord,
                       to fileURL: URL,
                       fileManager: FileManager = .default) throws -> Int {
        var records = load(from: fileURL)
        records.append(record)
        if records.count > maximumRecords {
            records.removeFirst(records.count - maximumRecords)
        }
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)
        try data.write(to: fileURL, options: .atomic)
        return records.count
    }
}
