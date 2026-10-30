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
    /// Historical v18 heart rate from the band, if the frame validates.
    let heartRateBPM: Int?
    /// Nil until an embedded physiological timestamp is independently decoded.
    let physiologicalTimestamp: Date?
    /// Present when a CRC-valid v18 frame could not be decoded as RR.
    let decodeError: String?
}

enum HistoricalRRPacketArchive {
    /// Retain up to 500 frames for each Type-47 revision independently.
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
        try append(contentsOf: [record], to: fileURL, fileManager: fileManager)
    }

    /// Batch append high-rate raw frames and keep a separate rolling window per revision.
    @discardableResult
    static func append(contentsOf newRecords: [HistoricalRRPacketRecord],
                       to fileURL: URL,
                       fileManager: FileManager = .default) throws -> Int {
        guard !newRecords.isEmpty else { return load(from: fileURL).count }
        var records = load(from: fileURL)
        records.append(contentsOf: newRecords)

        for revision in Set(newRecords.map { $0.revision }) {
            let matchingIndices = records.indices.filter { records[$0].revision == revision }
            let excess = matchingIndices.count - maximumRecords
            if excess > 0 {
                for index in matchingIndices.prefix(excess).reversed() {
                    records.remove(at: index)
                }
            }
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
