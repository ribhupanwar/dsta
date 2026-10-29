import Foundation

/// WHOOP 5.0 RR interval decoder.
///
/// Offsets and units are based on NOOP's real captured type-40 and v18 type-47
/// fixtures. The caller must validate the outer WHOOP frame CRC before calling.
enum Whoop5RRDecoder {
    enum DecodeError: Error, Equatable {
        case invalidFrame
        case wrongRecordType(Int)
        case unsupportedHistoricalVersion(Int)
        case invalidIntervalCount(Int)
        case invalidIntervalValue(Int)
        case truncatedIntervals(expectedBytes: Int, availableBytes: Int)
    }

    /// REALTIME_DATA (type 40): HR @16, count @17, u16 little-endian RR ms @18.
    static func decodeRealtime(_ frame: [UInt8]) throws -> [Int] {
        guard frame.count >= 22, frame[0] == 0xAA, frame[1] == 0x01 else {
            throw DecodeError.invalidFrame
        }
        guard Int(frame[8]) == 40 else {
            throw DecodeError.wrongRecordType(frame.count > 8 ? Int(frame[8]) : -1)
        }
        return try decodeWords(frame, countOffset: 17, wordsOffset: 18)
    }

    /// HISTORICAL_DATA v18 (type 47): version @9, HR @22, count @23,
    /// u16 little-endian RR ms @24. Other historical versions use other layouts.
    static func decodeHistoricalV18(_ frame: [UInt8]) throws -> [Int] {
        guard frame.count >= 28, frame[0] == 0xAA, frame[1] == 0x01 else {
            throw DecodeError.invalidFrame
        }
        guard Int(frame[8]) == 47 else {
            throw DecodeError.wrongRecordType(frame.count > 8 ? Int(frame[8]) : -1)
        }
        guard Int(frame[9]) == 18 else {
            throw DecodeError.unsupportedHistoricalVersion(frame.count > 9 ? Int(frame[9]) : -1)
        }
        return try decodeWords(frame, countOffset: 23, wordsOffset: 24)
    }

    private static func decodeWords(_ frame: [UInt8], countOffset: Int,
                                    wordsOffset: Int) throws -> [Int] {
        let count = Int(frame[countOffset])
        guard count <= 32 else { throw DecodeError.invalidIntervalCount(count) }
        let required = count * 2
        let available = max(0, frame.count - 4 - wordsOffset) // exclude trailing CRC32
        guard available >= required else {
            throw DecodeError.truncatedIntervals(expectedBytes: required, availableBytes: available)
        }
        let intervals = (0..<count).map { index -> Int in
            let offset = wordsOffset + index * 2
            return Int(frame[offset]) | (Int(frame[offset + 1]) << 8)
        }
        // Broad physiological guardrail: retain plausible bradycardic and
        // high-rate intervals while rejecting zero/padding and corrupt words.
        guard let invalid = intervals.first(where: { !(250...3000).contains($0) }) else {
            return intervals
        }
        throw DecodeError.invalidIntervalValue(invalid)
    }
}
