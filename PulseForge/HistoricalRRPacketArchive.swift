import Foundation

/// Append-only forensic archive for CRC-valid historical RR frames.
/// Receipt time is not physiological time; calculations must use the embedded
/// Gen5 timestamp only after its clock semantics have been validated.
struct HistoricalRRPacketRecord: Codable, Equatable {
    let receivedAt: Date
    let recordType: Int
    let revision: Int
    let intervalsMilliseconds: [Int]
    /// Per-second Gen5 v18 HR (0 means no reading); absent on older entries.
    var heartRateBpm: Int? = nil
    /// Raw band sleep-state byte; intentionally not mapped to sleep stages.
    var sleepStateRaw: UInt8? = nil
    let rawFrameHex: String
    let physiologicalTimestamp: Date?
    let decodeError: String?
}

enum HistoricalRRPacketArchive {
    /// Seven days at one record per second; compaction happens only at this limit.
    static let maximumRecords = 7 * 24 * 60 * 60
    private static let lock = NSLock()
    private static var cachedCounts: [String: Int] = [:]

    private static func encoder() -> JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        return value
    }

    private static func decoder() -> JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }

    static func load(from fileURL: URL) -> [HistoricalRRPacketRecord] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        // Backward compatibility with the previous JSON-array archive.
        if data.first == 0x5B {
            return (try? decoder().decode([HistoricalRRPacketRecord].self, from: data)) ?? []
        }
        return data.split(separator: 0x0A).compactMap {
            try? decoder().decode(HistoricalRRPacketRecord.self, from: Data($0))
        }
    }

    @discardableResult
    static func append(_ record: HistoricalRRPacketRecord,
                       to fileURL: URL,
                       fileManager: FileManager = .default) throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let key = fileURL.standardizedFileURL.path
        var count = cachedCounts[key]
        var legacyRecords: [HistoricalRRPacketRecord] = []

        if count == nil, let existing = try? Data(contentsOf: fileURL), !existing.isEmpty {
            if existing.first == 0x5B {
                legacyRecords = load(from: fileURL)
                count = legacyRecords.count
            } else {
                count = existing.reduce(into: 0) { total, byte in
                    if byte == 0x0A { total += 1 }
                }
            }
        }
        count = count ?? 0

        let encoded = try encoder().encode(record)
        var line = encoded
        line.append(0x0A)

        if !legacyRecords.isEmpty {
            // One-time migration; subsequent packets are O(1) append operations.
            var migrated = Data()
            for oldRecord in legacyRecords {
                migrated.append(try encoder().encode(oldRecord))
                migrated.append(0x0A)
            }
            try migrated.write(to: fileURL, options: .atomic)
        }

        if !fileManager.fileExists(atPath: fileURL.path) {
            guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        count! += 1

        if count! > maximumRecords {
            // Rare bounded-retention compaction, never performed on each packet.
            var records = load(from: fileURL)
            records = Array(records.suffix(maximumRecords))
            var compacted = Data()
            for item in records {
                compacted.append(try encoder().encode(item))
                compacted.append(0x0A)
            }
            try compacted.write(to: fileURL, options: .atomic)
            count = records.count
        }

        cachedCounts[key] = count
        return count!
    }
}
