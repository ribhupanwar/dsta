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
        // Migrate old v18 archives: their candidate words were previously
        // stored under an ms-labelled field despite unverified units.
        if revision == 18, storedRawWords == nil {
            intervalsMilliseconds = []
            rawRRWords = storedMilliseconds
        } else {
            intervalsMilliseconds = storedMilliseconds
            rawRRWords = storedRawWords
        }
        rawFrameHex = try values.decode(String.self, forKey: .rawFrameHex)
        heartRateBPM = try values.decodeIfPresent(Int.self, forKey: .heartRateBPM)
        physiologicalTimestamp = try values.decodeIfPresent(Date.self, forKey: .physiologicalTimestamp)
        decodeError = try values.decodeIfPresent(String.self, forKey: .decodeError)
    }
}

enum HistoricalRRPacketArchive {
    /// Keep a full-day-plus forensic window for compact v18 biometric frames.
    /// Large motion-oriented revisions retain a smaller bounded window.
    static let maximumRecords = 100_000
    static let maximumRecordsForOtherRevisions = 500

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
