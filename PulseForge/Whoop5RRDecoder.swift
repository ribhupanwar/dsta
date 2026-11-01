import Foundation

/// Candidate WHOOP 5.0 RR interval decoder; field offsets are not yet IPA-verified.
///
/// Current offsets/units come from NOOP's captured type-40 and v18 type-47 fixtures.
/// Static inspection of WHOOP 5.75.0 confirms related packet abstractions and RR
/// symbols, but does not expose enough field-level layout to independently verify
/// these offsets. Keep this provenance explicit until matched to WHOOP device captures.
/// The caller must validate the outer WHOOP frame CRC before calling.
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
        return try decodeWords(frame, countOffset: 17, wordsOffset: 18, maximumCount: 32, signedWords: false, validRange: 250...3000)
    }

    /// Candidate HISTORICAL_DATA v18 layout (type 47), currently NOOP-fixture-derived:
    /// version @9, HR @22, count @23, u16 little-endian RR ms @24.
    /// Other historical versions use other layouts.
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
        return try decodeWords(frame, countOffset: 23, wordsOffset: 24, maximumCount: 4, signedWords: true, validRange: 200...2500)
    }

    /// Gen5 historical header timestamp: unix seconds @ frame[15...18]
    /// and Q15 fractional second @ frame[19...20]. These are the frame-absolute
    /// coordinates of inner[7...12] after the 8-byte Gen5 envelope/header.
    /// Receipt time must never be substituted for this physiological time.
    static func decodeHistoricalV18Timestamp(_ frame: [UInt8]) -> Date? {
        guard frame.count >= 21,
              frame[0] == 0xAA, frame[1] == 0x01,
              Int(frame[8]) == 47, Int(frame[9]) == 18 else { return nil }
        let seconds = UInt32(frame[15])
            | (UInt32(frame[16]) << 8)
            | (UInt32(frame[17]) << 16)
            | (UInt32(frame[18]) << 24)
        let fractionQ15 = UInt16(frame[19]) | (UInt16(frame[20]) << 8)
        return Date(timeIntervalSince1970: TimeInterval(seconds)
                    + TimeInterval(fractionQ15) / 32768.0)
    }

    private static func decodeWords(_ frame: [UInt8], countOffset: Int,
                                    wordsOffset: Int, maximumCount: Int,
                                    signedWords: Bool,
                                    validRange: ClosedRange<Int>) throws -> [Int] {
        let count = Int(frame[countOffset])
        guard count <= maximumCount else { throw DecodeError.invalidIntervalCount(count) }
        let required = count * 2
        let available = max(0, frame.count - 4 - wordsOffset) // exclude trailing CRC32
        guard available >= required else {
            throw DecodeError.truncatedIntervals(expectedBytes: required, availableBytes: available)
        }
        let intervals = (0..<count).map { index -> Int in
            let offset = wordsOffset + index * 2
            let raw = Int(frame[offset]) | (Int(frame[offset + 1]) << 8)
            if signedWords && raw >= 0x8000 { return raw - 0x10000 }
            return raw
        }
        // Gen5 v18 has four signed i16 RR slots. Match the reference decoder's
        // accepted physiological range; do not consume following fields as RR.
        guard let invalid = intervals.first(where: { !validRange.contains($0) }) else {
            return intervals
        }
        throw DecodeError.invalidIntervalValue(invalid)
    }
}

/// Freshness gate for source arbitration: a future-dated or stale WHOOP packet
/// must not suppress the standard BLE fallback indefinitely.
enum WhoopRealtimeFreshness {
    static func isFresh(lastPacketAt: Date?, now: Date,
                        maximumAge: TimeInterval = 30) -> Bool {
        guard let lastPacketAt, maximumAge >= 0 else { return false }
        let age = now.timeIntervalSince(lastPacketAt)
        return age >= 0 && age <= maximumAge
    }
}


/// Short-window RMSSD from contiguous realtime RR intervals only.
/// This is a live diagnostic, not overnight HRV and not a Recovery input.
enum RealtimeRMSSDCalculator {
    static func calculate(intervalsMilliseconds: [Int],
                          minimumIntervals: Int = 5,
                          maximumAdjacentDifference: Int = 300) -> Double? {
        guard minimumIntervals >= 3,
              intervalsMilliseconds.count >= minimumIntervals,
              intervalsMilliseconds.allSatisfy({ (250...3000).contains($0) }) else {
            return nil
        }
        let differences = zip(intervalsMilliseconds, intervalsMilliseconds.dropFirst()).map { pair in
            pair.1 - pair.0
        }
        guard differences.allSatisfy({ abs($0) <= maximumAdjacentDifference }) else {
            return nil
        }
        let meanSquaredDifference = differences
            .map { Double($0) * Double($0) }
            .reduce(0, +) / Double(differences.count)
        let result = meanSquaredDifference.squareRoot()
        return result.isFinite ? result : nil
    }
}
