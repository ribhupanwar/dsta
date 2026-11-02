import Foundation

/// Durable forensic archive for CRC-valid historical RR frames.
/// receivedAt is the phone's receipt time, NOT the physiological sample time.
/// Do not use these records for overnight HRV until the packet's embedded
/// timestamp/layout has been independently verified.
struct HistoricalRRPacketRecord: Codable, Equatable {
    let receivedAt: Date
    let recordType: Int
    /// Observed byte-9 marker for Type-47 records; its semantic role is not
    /// assumed to be a revision until the original WHOOP parser is mapped.
    let revision: Int
    /// Only populated after RR units and field offsets are verified.
    let intervalsMilliseconds: [Int]
    /// Candidate words copied from a raw frame without claiming units.
    var rawRRWords: [Int]? = nil
    /// Values previously labelled milliseconds by unverified builds. Preserved
    /// separately so they can never be confused with raw UInt16 words.
    var legacyUnverifiedRRValues: [Int]? = nil
    let rawFrameHex: String
    /// Nil for current Type-47 v18 candidate layouts; no HR field is trusted yet.
    let heartRateBPM: Int?
    /// Nil until an embedded physiological timestamp is verified from WHOOP code.
    let physiologicalTimestamp: Date?
    let decodeError: String?
    /// True only when an original-WHOOP/device-verified layout and units are known.
    let physiologyLayoutVerified: Bool

    init(receivedAt: Date, recordType: Int, revision: Int,
         intervalsMilliseconds: [Int], rawRRWords: [Int]? = nil,
         legacyUnverifiedRRValues: [Int]? = nil,
         rawFrameHex: String, heartRateBPM: Int?,
         physiologicalTimestamp: Date?, decodeError: String?,
         physiologyLayoutVerified: Bool = false) {
        self.receivedAt = receivedAt
        self.recordType = recordType
        self.revision = revision
        self.intervalsMilliseconds = intervalsMilliseconds
        self.rawRRWords = rawRRWords
        self.legacyUnverifiedRRValues = legacyUnverifiedRRValues
        self.rawFrameHex = rawFrameHex
        self.heartRateBPM = heartRateBPM
        self.physiologicalTimestamp = physiologicalTimestamp
        self.decodeError = decodeError
        self.physiologyLayoutVerified = physiologyLayoutVerified
    }

    private enum CodingKeys: String, CodingKey {
        case receivedAt, recordType, revision, intervalsMilliseconds
        case rawRRWords, legacyUnverifiedRRValues, rawFrameHex, heartRateBPM, physiologicalTimestamp, decodeError
        case physiologyLayoutVerified
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        receivedAt = try values.decode(Date.self, forKey: .receivedAt)
        recordType = try values.decode(Int.self, forKey: .recordType)
        revision = try values.decode(Int.self, forKey: .revision)
        let storedMilliseconds = try values.decodeIfPresent([Int].self, forKey: .intervalsMilliseconds) ?? []
        let storedRawWords = try values.decodeIfPresent([Int].self, forKey: .rawRRWords)
        let storedLegacyValues = try values.decodeIfPresent([Int].self, forKey: .legacyUnverifiedRRValues)
        let storedHeartRate = try values.decodeIfPresent(Int.self, forKey: .heartRateBPM)
        let storedTimestamp = try values.decodeIfPresent(Date.self, forKey: .physiologicalTimestamp)
        let verifiedLayout = try values.decodeIfPresent(Bool.self, forKey: .physiologyLayoutVerified) ?? false
        rawFrameHex = try values.decode(String.self, forKey: .rawFrameHex)

        if recordType == 47 && revision == 18 {
            // WHOOP's original executable does not confirm the Type-47 v18
            // RR/HR/time offsets or RR units. Downgrade even records an earlier
            // PulseForge build marked verified. Keep raw words only after CRC
            // validation; preserve old converted numbers in a separate field.
            var candidateWordsFromFrame: [Int]?
            if rawFrameHex.count.isMultiple(of: 2) {
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
                if validHex, Whoop5FrameValidator.isValid(bytes) {
                    candidateWordsFromFrame = try? Whoop5RRDecoder.decodeHistoricalV18CandidateRRWords(bytes)
                }
            }
            intervalsMilliseconds = []
            // Empty arrays in older archives are placeholders, not evidence that
            // a candidate payload or previously stored values were present.
            // Prefer a fresh CRC-valid extraction; otherwise retain only non-empty
            // stored raw words. Preserve older converted values as explicitly
            // unverified when the newer migration field is empty.
            rawRRWords = candidateWordsFromFrame ?? (storedRawWords?.isEmpty == false ? storedRawWords : nil)
            legacyUnverifiedRRValues = storedLegacyValues?.isEmpty == false
                ? storedLegacyValues
                : (storedMilliseconds.isEmpty ? nil : storedMilliseconds)
            heartRateBPM = nil
            physiologicalTimestamp = nil
            physiologyLayoutVerified = false
        } else {
            intervalsMilliseconds = storedMilliseconds
            rawRRWords = storedRawWords
            legacyUnverifiedRRValues = storedLegacyValues
            heartRateBPM = storedHeartRate
            physiologicalTimestamp = storedTimestamp
            physiologyLayoutVerified = verifiedLayout
        }
        decodeError = try values.decodeIfPresent(String.self, forKey: .decodeError)
    }

    /// Preserve an unmapped CRC-valid Type-47 frame verbatim. Byte 9 is stored
    /// only as a candidate marker; it is not asserted to be a revision or R24 field.
    static func unmappedType47Candidate(frame: [UInt8],
                                        receivedAt: Date) -> HistoricalRRPacketRecord? {
        guard frame.count > 9, frame[8] == 47,
              Whoop5FrameValidator.isValid(frame) else { return nil }
        let marker = Int(frame[9])
        let rawHex = frame.map { String(format: "%02X", $0) }.joined()
        return HistoricalRRPacketRecord(
            receivedAt: receivedAt,
            recordType: 47,
            revision: marker,
            intervalsMilliseconds: [],
            rawRRWords: nil,
            legacyUnverifiedRRValues: nil,
            rawFrameHex: rawHex,
            heartRateBPM: nil,
            physiologicalTimestamp: nil,
            decodeError: "Unmapped Type-47 raw frame · byte[9] candidate marker \(marker) · no field interpretation",
            physiologyLayoutVerified: false
        )
    }
}

enum HistoricalRRPacketArchive {
    /// Keep a large bounded forensic window for compact v18 frames.
    /// Wall-clock coverage depends on packet cadence and frame size; no fixed duration is assumed.
    /// Large motion-oriented revisions retain a smaller bounded window.
    static let maximumRecords = 100_000
    static let maximumRecordsForOtherRevisions = 500

    private struct RetentionGroup: Hashable {
        let recordType: Int
        let revision: Int
    }

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
        guard !newRecords.isEmpty else {
            return try loadThrowing(from: fileURL, fileManager: fileManager).count
        }
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

        let retentionGroups = Set(newRecords.map {
            RetentionGroup(recordType: $0.recordType, revision: $0.revision)
        })
        for group in retentionGroups {
            let matchingIndices = records.indices.filter {
                records[$0].recordType == group.recordType &&
                    records[$0].revision == group.revision
            }
            let limit = group.recordType == 47 && group.revision == 18
                ? maximumRecords : maximumRecordsForOtherRevisions
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
