import Foundation

/// Durable forensic archive for CRC-valid historical RR frames.
/// receivedAt is the phone's receipt time, NOT the physiological sample time.
/// Do not use these records for overnight HRV until the packet's embedded
/// timestamp/layout has been independently verified.
struct HistoricalRRPacketRecord: Codable, Equatable {
    let receivedAt: Date
    let recordType: Int
    let revision: Int
    /// Only populated after RR units have been independently verified.
    let intervalsMilliseconds: [Int]
    /// Candidate v18 little-endian words, retained without claiming milliseconds.
    var rawRRWords: [Int]? = nil
    let rawFrameHex: String
    /// Historical v18 heart rate from the band, if the frame validates.
    let heartRateBPM: Int?
    /// Nil until an embedded physiological timestamp is independently decoded.
    let physiologicalTimestamp: Date?
    /// Present when a CRC-valid v18 frame could not be decoded as RR.
    let decodeError: String?
    /// Explicit migration guard: only records written by the verified v18 decoder
    /// may retain HR, RR milliseconds and physiological timestamps on reload.
    let physiologyLayoutVerified: Bool

    init(receivedAt: Date, recordType: Int, revision: Int,
         intervalsMilliseconds: [Int], rawRRWords: [Int]? = nil,
         rawFrameHex: String, heartRateBPM: Int?,
         physiologicalTimestamp: Date?, decodeError: String?,
         physiologyLayoutVerified: Bool = false) {
        self.receivedAt = receivedAt
        self.recordType = recordType
        self.revision = revision
        self.intervalsMilliseconds = intervalsMilliseconds
        self.rawRRWords = rawRRWords
        self.rawFrameHex = rawFrameHex
        self.heartRateBPM = heartRateBPM
        self.physiologicalTimestamp = physiologicalTimestamp
        self.decodeError = decodeError
        self.physiologyLayoutVerified = physiologyLayoutVerified
    }

    private enum CodingKeys: String, CodingKey {
        case receivedAt, recordType, revision, intervalsMilliseconds
        case rawRRWords, rawFrameHex, heartRateBPM, physiologicalTimestamp, decodeError
        case physiologyLayoutVerified
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        receivedAt = try values.decode(Date.self, forKey: .receivedAt)
        recordType = try values.decode(Int.self, forKey: .recordType)
        revision = try values.decode(Int.self, forKey: .revision)
        let storedMilliseconds = try values.decodeIfPresent([Int].self, forKey: .intervalsMilliseconds) ?? []
        let storedRawWords = try values.decodeIfPresent([Int].self, forKey: .rawRRWords)
        let storedHeartRate = try values.decodeIfPresent(Int.self, forKey: .heartRateBPM)
        let storedTimestamp = try values.decodeIfPresent(Date.self, forKey: .physiologicalTimestamp)
        let verifiedLayout = try values.decodeIfPresent(Bool.self, forKey: .physiologyLayoutVerified) ?? false
        rawFrameHex = try values.decode(String.self, forKey: .rawFrameHex)

        // Re-decode legacy raw v18 frames during migration. Earlier builds saved
        // CRC-valid rawFrameHex and candidate words but intentionally withheld
        // their physiological fields. The verified decoder can now recover the
        // exact unix/HR/RR values without asking the user to repeat the offload.
        let migratedV18: Whoop5RRDecoder.HistoricalV18Biometrics?
        if revision == 18 && !verifiedLayout,
           rawFrameHex.count.isMultiple(of: 2) {
            let chars = Array(rawFrameHex.utf8)
            var bytes: [UInt8] = []
            bytes.reserveCapacity(chars.count / 2)
            var validHex = true
            for index in stride(from: 0, to: chars.count, by: 2) {
                guard let byte = UInt8(String(decoding: chars[index..<(index + 2)], as: UTF8.self), radix: 16) else {
                    validHex = false
                    break
                }
                bytes.append(byte)
            }
            migratedV18 = validHex ? try? Whoop5RRDecoder.decodeHistoricalV18Biometrics(bytes) : nil
        } else {
            migratedV18 = nil
        }

        if let migratedV18 {
            intervalsMilliseconds = migratedV18.rrIntervalsMilliseconds
            rawRRWords = migratedV18.rawRRWords
            heartRateBPM = migratedV18.heartRateBPM
            physiologicalTimestamp = migratedV18.timestamp
            physiologyLayoutVerified = true
        } else if revision == 18 && !verifiedLayout {
            // Legacy v18 records whose raw frame cannot be decoded are retained
            // as forensic raw words only; never trust the old ms/HR/time labels.
            intervalsMilliseconds = []
            rawRRWords = storedRawWords ?? (storedMilliseconds.isEmpty ? nil : storedMilliseconds)
            heartRateBPM = nil
            physiologicalTimestamp = nil
            physiologyLayoutVerified = false
        } else {
            intervalsMilliseconds = storedMilliseconds
            rawRRWords = storedRawWords
            heartRateBPM = storedHeartRate
            physiologicalTimestamp = storedTimestamp
            physiologyLayoutVerified = verifiedLayout
        }
        decodeError = try values.decodeIfPresent(String.self, forKey: .decodeError)
    }
}

enum HistoricalRRPacketArchive {
    /// Keep a large bounded forensic window for compact v18 frames.
    /// Wall-clock coverage depends on packet cadence and frame size; no fixed duration is assumed.
    /// Large motion-oriented revisions retain a smaller bounded window.
    static let maximumRecords = 100_000
    static let maximumRecordsForOtherRevisions = 500

    /// Throwing read for diagnostics and recovery flows that must distinguish a
    /// missing archive from a corrupt or inaccessible one. A missing file is a
    /// valid empty archive; decoding and I/O failures are surfaced to the caller.
    static func loadThrowing(from fileURL: URL,
                             fileManager: FileManager = .default) throws -> [HistoricalRRPacketRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([HistoricalRRPacketRecord].self, from: data)
    }

    /// Backward-compatible convenience read. Prefer loadThrowing when an empty
    /// result must not hide a corrupt archive.
    static func load(from fileURL: URL) -> [HistoricalRRPacketRecord] {
        (try? loadThrowing(from: fileURL)) ?? []
    }

    /// Export through the decoding/migration path so legacy v18 candidate HR/time
    /// fields are never re-emitted as trusted physiological values.
    /// Returns nil for unreadable or corrupt files; it never rewrites the source archive.
    static func exportJSON(from fileURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let records = try? loadThrowing(from: fileURL) else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let normalized = try? encoder.encode(records) else { return nil }
        return String(data: normalized, encoding: .utf8)
    }

    @discardableResult
    static func append(_ record: HistoricalRRPacketRecord,
                       to fileURL: URL,
                       fileManager: FileManager = .default) throws -> Int {
        try append(contentsOf: [record], to: fileURL, fileManager: fileManager)
    }

    private static func retentionDate(for record: HistoricalRRPacketRecord) -> Date {
        guard record.recordType == 47,
              record.revision == 18,
              record.physiologyLayoutVerified,
              let timestamp = record.physiologicalTimestamp else {
            return record.receivedAt
        }
        return timestamp
    }

    /// Batch append high-rate raw frames and keep a separate rolling window per revision.
    @discardableResult
    static func append(contentsOf newRecords: [HistoricalRRPacketRecord],
                       to fileURL: URL,
                       fileManager: FileManager = .default) throws -> Int {
        guard !newRecords.isEmpty else { return load(from: fileURL).count }
        // A corrupt existing archive must never be mistaken for an empty
        // archive and silently overwritten by the next batch.
        var records = try loadThrowing(from: fileURL, fileManager: fileManager)
        records.append(contentsOf: newRecords)

        // Historical offloads can be replayed after reconnects. The same CRC-valid
        // frame adds no new evidence, so keep its first receipt instead of letting
        // duplicate backfills consume the bounded retention window.
        var seenFrames = Set<String>()
        records = records.filter { record in
            guard !record.rawFrameHex.isEmpty else { return true }
            let identity = "\(record.recordType):\(record.revision):\(record.rawFrameHex.uppercased())"
            return seenFrames.insert(identity).inserted
        }

        for revision in Set(newRecords.map { $0.revision }) {
            let matchingIndices = records.indices.filter { records[$0].revision == revision }
            let limit = revision == 18 ? maximumRecords : maximumRecordsForOtherRevisions
            let excess = matchingIndices.count - limit
            guard excess > 0 else { continue }

            // For verified v18 records, retain the newest physiological history,
            // not whichever frames happened to arrive last during a replay.
            // Unknown layouts have no trusted sample time and use receipt time.
            let oldestIndices = matchingIndices.sorted { lhs, rhs in
                let left = records[lhs]
                let right = records[rhs]
                let leftTime = retentionDate(for: left)
                let rightTime = retentionDate(for: right)
                if leftTime != rightTime { return leftTime < rightTime }
                if left.receivedAt != right.receivedAt {
                    return left.receivedAt < right.receivedAt
                }
                if left.rawFrameHex != right.rawFrameHex {
                    return left.rawFrameHex < right.rawFrameHex
                }
                return lhs < rhs
            }.prefix(excess)
            let remove = Set(oldestIndices)
            records = records.enumerated().compactMap { index, record in
                remove.contains(index) ? nil : record
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
