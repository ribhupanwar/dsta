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

    /// REALTIME_DATA (type 40): HR @16, count @17, u16 little-endian RR ticks @18.
    /// WHOOP 5.0 uses 1/1024-second ticks; convert to integer milliseconds.
    static func decodeRealtime(_ frame: [UInt8]) throws -> [Int] {
        guard frame.count >= 22, frame[0] == 0xAA, frame[1] == 0x01 else {
            throw DecodeError.invalidFrame
        }
        guard Int(frame[8]) == 40 else {
            throw DecodeError.wrongRecordType(frame.count > 8 ? Int(frame[8]) : -1)
        }
        let ticks = try decodeRawWords(frame, countOffset: 17, wordsOffset: 18)
        return ticks.map { ($0 * 1000 + 512) / 1024 }
    }

    /// HISTORICAL_DATA v18 candidate layout (type 47):
    /// version @9, HR @22, count @23, little-endian words @24.
    /// Historical R18 RR units are not yet independently verified against
    /// WHOOP IPA or a timestamp-aligned official export; return raw words only.
    /// Do not feed these values into physiological calculations until verified.
    static func decodeHistoricalV18CandidateRRWords(_ frame: [UInt8]) throws -> [Int] {
        guard frame.count >= 28, frame[0] == 0xAA, frame[1] == 0x01 else {
            throw DecodeError.invalidFrame
        }
        guard Int(frame[8]) == 47 else {
            throw DecodeError.wrongRecordType(frame.count > 8 ? Int(frame[8]) : -1)
        }
        guard Int(frame[9]) == 18 else {
            throw DecodeError.unsupportedHistoricalVersion(frame.count > 9 ? Int(frame[9]) : -1)
        }
        let count = Int(frame[23])
        guard count <= 4 else { throw DecodeError.invalidIntervalCount(count) }
        return try decodeRawWords(frame, countOffset: 23, wordsOffset: 24)
    }

    /// Candidate timestamp extraction from the NOOP-derived fixture only.
    /// The WHOOP IPA does not establish this offset or epoch; never publish this
    /// value as a physiological timestamp without independent device correlation.
    static func decodeCandidateHistoricalTimestampV18(_ frame: [UInt8]) throws -> Date {
        guard frame.count >= 19, frame[0] == 0xAA, frame[1] == 0x01 else {
            throw DecodeError.invalidFrame
        }
        guard Int(frame[8]) == 47 else {
            throw DecodeError.wrongRecordType(frame.count > 8 ? Int(frame[8]) : -1)
        }
        guard Int(frame[9]) == 18 else {
            throw DecodeError.unsupportedHistoricalVersion(frame.count > 9 ? Int(frame[9]) : -1)
        }
        let seconds = UInt32(frame[15])
            | (UInt32(frame[16]) << 8)
            | (UInt32(frame[17]) << 16)
            | (UInt32(frame[18]) << 24)
        guard seconds >= 1_577_836_800, seconds <= 4_102_444_800 else {
            throw DecodeError.invalidFrame
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Candidate HR-byte extraction from the NOOP-derived fixture only.
    /// The WHOOP IPA does not establish this offset; do not publish it as BPM.
    static func decodeCandidateHistoricalHeartRateV18(_ frame: [UInt8]) throws -> Int {
        guard frame.count >= 23, frame[0] == 0xAA, frame[1] == 0x01 else {
            throw DecodeError.invalidFrame
        }
        guard Int(frame[8]) == 47 else {
            throw DecodeError.wrongRecordType(frame.count > 8 ? Int(frame[8]) : -1)
        }
        guard Int(frame[9]) == 18 else {
            throw DecodeError.unsupportedHistoricalVersion(frame.count > 9 ? Int(frame[9]) : -1)
        }
        let bpm = Int(frame[22])
        guard (25...240).contains(bpm) else {
            throw DecodeError.invalidIntervalValue(bpm)
        }
        return bpm
    }

    private static func decodeWords(_ frame: [UInt8], countOffset: Int,
                                    wordsOffset: Int) throws -> [Int] {
        try decodeRawWords(frame, countOffset: countOffset, wordsOffset: wordsOffset)
    }

    private static func decodeRawWords(_ frame: [UInt8], countOffset: Int,
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


/// Distinguishes a CoreBluetooth write acknowledgement from actual band-side
/// history progress. A successful write only means the ACK frame was written;
/// HISTORY_START / subsequent records are still required as transfer evidence.
enum HistoricalAckWriteState: Equatable {
    case acknowledgedAwaitingBandProgress
    case failed(String)

    static func resolve(errorDescription: String?) -> HistoricalAckWriteState {
        guard let errorDescription, !errorDescription.isEmpty else {
            return .acknowledgedAwaitingBandProgress
        }
        return .failed(errorDescription)
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
