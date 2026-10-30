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

    init(receivedAt: Date, recordType: Int, revision: Int,
         intervalsMilliseconds: [Int], rawRRWords: [Int]? = nil,
         rawFrameHex: String, heartRateBPM: Int?,
         physiologicalTimestamp: Date?, decodeError: String?) {
        self.receivedAt = receivedAt
        self.recordType = recordType
        self.revision = revision
        self.intervalsMilliseconds = intervalsMilliseconds
        self.rawRRWords = rawRRWords
        self.rawFrameHex = rawFrameHex
        self.heartRateBPM = heartRateBPM
        self.physiologicalTimestamp = physiologicalTimestamp
        self.decodeError = decodeError
    }

    private enum CodingKeys: String, CodingKey {
        case receivedAt, recordType, revision, intervalsMilliseconds
        case rawRRWords, rawFrameHex, heartRateBPM, physiologicalTimestamp, decodeError
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
        // All current v18 offsets are still NOOP-fixture candidates. Migrate the
        // old ms-labelled words to rawRRWords and discard candidate HR/time fields.
        if revision == 18 {
            intervalsMilliseconds = []
            rawRRWords = storedRawWords ?? (storedMilliseconds.isEmpty ? nil : storedMilliseconds)
            heartRateBPM = nil
            physiologicalTimestamp = nil
        } else {
            intervalsMilliseconds = storedMilliseconds
            rawRRWords = storedRawWords
            heartRateBPM = storedHeartRate
            physiologicalTimestamp = storedTimestamp
        }
        rawFrameHex = try values.decode(String.self, forKey: .rawFrameHex)
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

    /// Batch append high-rate raw frames and keep a separate rolling window per revision.
    @discardableResult
    static func append(contentsOf newRecords: [HistoricalRRPacketRecord],
                       to fileURL: URL,
                       fileManager: FileManager = .default) throws -> Int {
        guard !newRecords.isEmpty else { return load(from: fileURL).count }
        var records: [HistoricalRRPacketRecord] = []
        // A corrupt existing archive must never be mistaken for an empty
        // archive and silently overwritten by the next batch.
        records = try loadThrowing(from: fileURL, fileManager: fileManager)
        records.append(contentsOf: newRecords)

        for revision in Set(newRecords.map { $0.revision }) {
            let matchingIndices = records.indices.filter { records[$0].revision == revision }
            let limit = revision == 18 ? maximumRecords : maximumRecordsForOtherRevisions
            let excess = matchingIndices.count - limit
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
