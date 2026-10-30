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

    /// Type-40 extraction using the NOOP Gen5 REALTIME_DATA layout:
    /// count @17 and little-endian UInt16 RR milliseconds @18+.
    /// The frame must already have passed the outer WHOOP CRC validation.
    static func decodeRealtimeCandidateRRWords(_ frame: [UInt8]) throws -> [Int] {
        guard frame.count >= 22, frame[0] == 0xAA, frame[1] == 0x01 else {
            throw DecodeError.invalidFrame
        }
        guard Int(frame[8]) == 40 else {
            throw DecodeError.wrongRecordType(frame.count > 8 ? Int(frame[8]) : -1)
        }
        return try decodeRawWords(frame, countOffset: 17, wordsOffset: 18)
    }

    /// WHOOP 5.0 Type-40 RR values are already little-endian milliseconds.
    /// NOOP's Gen5 interpreter documents count @17 and values @18+ (u16, ms),
    /// matching the user's CRC-valid Type-40 captures. Do not apply a tick conversion.
    /// Zero placeholders are omitted; implausible values reject the batch.
    static func decodeRealtimeRRIntervalsMilliseconds(_ frame: [UInt8]) throws -> [Int] {
        let rawWords = try decodeRealtimeCandidateRRWords(frame)
        var intervals: [Int] = []
        intervals.reserveCapacity(rawWords.count)
        for milliseconds in rawWords where milliseconds > 0 {
            guard (250...3000).contains(milliseconds) else {
                throw DecodeError.invalidIntervalValue(milliseconds)
            }
            intervals.append(milliseconds)
        }
        return intervals
    }

    /// Device-correlated WHOOP 5.0 REALTIME_DATA HR byte at absolute offset 16.
    /// Correlated against 19 CRC-valid 32-byte WHOOP 5.0 device frames captured
    /// 2026-10-30; candidate must still pass a conservative physiological bound.
    static func decodeRealtimeHeartRate(_ frame: [UInt8]) throws -> Int {
        guard frame.count >= 22, frame[0] == 0xAA, frame[1] == 0x01 else {
            throw DecodeError.invalidFrame
        }
        guard Int(frame[8]) == 40 else {
            throw DecodeError.wrongRecordType(frame.count > 8 ? Int(frame[8]) : -1)
        }
        let bpm = Int(frame[16])
        guard (25...240).contains(bpm) else {
            throw DecodeError.invalidIntervalValue(bpm)
        }
        return bpm
    }

    /// HISTORICAL_DATA v18 candidate layout (type 47):
    /// version @9, candidate count @23, candidate little-endian words @24.
    /// Offsets and units are not WHOOP-verified; return raw words only.
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
        // Defensive bound for this candidate parser, not a WHOOP protocol maximum.
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

    private static func decodeRawWords(_ frame: [UInt8], countOffset: Int,
                                       wordsOffset: Int) throws -> [Int] {
        let count = Int(frame[countOffset])
        // Defensive allocation bound only; this is not a claimed WHOOP maximum.
        guard count <= 32 else { throw DecodeError.invalidIntervalCount(count) }
        let required = count * 2
        let available = max(0, frame.count - 4 - wordsOffset) // exclude trailing CRC32
        guard available >= required else {
            throw DecodeError.truncatedIntervals(expectedBytes: required, availableBytes: available)
        }
        // Preserve every candidate UInt16 word, including zero/padding and values
        // outside physiological ranges. Their meaning and units are unverified.
        return (0..<count).map { index -> Int in
            let offset = wordsOffset + index * 2
            return Int(frame[offset]) | (Int(frame[offset + 1]) << 8)
        }
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
