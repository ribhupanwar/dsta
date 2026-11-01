import Foundation

/// Durable forensic archive for CRC-valid WHOOP Type-47 frames whose payload
/// layout has not yet been independently identified. Raw bytes are retained;
/// this type deliberately does not interpret step counters or other fields.
struct HistoricalWhoopPacketRecord: Codable, Equatable {
    let receivedAt: Date
    let channel: String
    let packetType: Int
    let revision: Int?
    let byteCount: Int
    let transportCRCValidated: Bool
    let rawFrameHex: String
    let classification: String
}

enum HistoricalWhoopPacketArchive {
    static let maximumRecords = 500

    static func load(from fileURL: URL) -> [HistoricalWhoopPacketRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoricalWhoopPacketRecord].self, from: data)) ?? []
    }

    @discardableResult
    static func append(
        _ record: HistoricalWhoopPacketRecord,
        to fileURL: URL,
        maximumRecords: Int = maximumRecords,
        fileManager: FileManager = .default
    ) throws -> Int {
        let limit = max(1, maximumRecords)
        var records = load(from: fileURL)
        records.append(record)
        if records.count > limit {
            records.removeFirst(records.count - limit)
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)
        try data.write(to: fileURL, options: .atomic)
        return records.count
    }
}
