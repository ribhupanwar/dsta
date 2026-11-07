import Foundation

/// Candidate field extraction for WHOOP 5.0 frames.
/// The original WHOOP 5.75.0 executable does not yet confirm the Type-40 RR or
/// Type-47 v18 offsets/units. Keep RR values as raw words; never infer milliseconds
/// or physiological timestamps from these candidate layouts. The caller validates
/// the complete outer frame CRC before parsing.
enum Whoop5RRDecoder {
    enum DecodeError: Error, Equatable {
        case invalidFrame
        case wrongRecordType(Int)
        case unsupportedHistoricalVersion(Int)
        case invalidIntervalCount(Int)
        case invalidIntervalValue(Int)
        case truncatedIntervals(expectedBytes: Int, availableBytes: Int)
    }

    /// Type-40 raw RR candidate words at secondary-reference offsets. Their units
    /// and field mapping are not verified against the original WHOOP parser.
    static func decodeRealtimeCandidateRRWords(_ frame: [UInt8]) throws -> [Int] {
        guard frame.count >= 22, frame[0] == 0xAA, frame[1] == 0x01 else {
            throw DecodeError.invalidFrame
        }
        guard Int(frame[8]) == 40 else {
            throw DecodeError.wrongRecordType(frame.count > 8 ? Int(frame[8]) : -1)
        }
        return try decodeRawWords(frame, countOffset: 17, wordsOffset: 18)
    }

    /// Experimental Type-40 motion-field candidates from NOOP/OpenStrap.
    /// These offsets are not verified against WHOOP's original parser. No timestamp
    /// is decoded and these values must never be accumulated into daily steps.
    struct RealtimeStepCounterCandidate: Equatable {
        let selectedCounterCandidate: Int
        let hardwareCounterCandidate: Int
        let cadenceRawCandidate: Int
        let activityRawCandidate: Int
        let softwareOverrideCandidate: Bool
    }

    static func decodeRealtimeStepCounterCandidate(_ frame: [UInt8]) throws -> RealtimeStepCounterCandidate {
        guard frame.count >= 65, frame[0] == 0xAA, frame[1] == 0x01,
              Int(frame[8]) == 40 else { throw DecodeError.invalidFrame }
        let selected = Int(frame[57]) | (Int(frame[58]) << 8)
        let hardware = Int(frame[61]) | (Int(frame[62]) << 8)
        guard frame[64] == 0x00 || frame[64] == 0x10 else {
            throw DecodeError.invalidFrame
        }
        return RealtimeStepCounterCandidate(
            selectedCounterCandidate: selected,
            hardwareCounterCandidate: hardware,
            cadenceRawCandidate: Int(frame[59]),
            activityRawCandidate: Int(frame[63]),
            softwareOverrideCandidate: frame[64] == 0x10
        )
    }

    /// Device-correlated Type-40 HR candidate at byte 16 from CRC-valid WHOOP 5.0
    /// captures. This device correlation supports the live HR path, but is not a
    /// recovered field-level parser from the original WHOOP executable.
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

    /// Type-47 v18 candidate raw-word extraction using secondary-reference offsets.
    /// Byte 9 is a candidate marker; count/word offsets are not verified by the
    /// original WHOOP parser. Values are raw candidates, not milliseconds.
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

    /// Experimental Type-47 v18 motion-field candidates from OpenStrap.
    /// WHOOP's original executable identifies a separate Historical Processed
    /// Steps Packet (R24), but does not confirm these v18 offsets or their units.
    /// This candidate decoder returns no timestamp and must not feed daily steps.
    struct HistoricalV18StepCounterCandidate: Equatable {
        let stepMotionCounterCandidate: Int
        let hardwareCounterCandidate: Int
        let softwareOverrideCandidate: Bool
        let stepCadenceRawCandidate: Int
        let activityClassRawCandidate: Int
    }

    static func decodeHistoricalV18StepCounterCandidate(_ frame: [UInt8]) throws -> HistoricalV18StepCounterCandidate {
        guard frame.count >= 65, frame[0] == 0xAA, frame[1] == 0x01 else {
            throw DecodeError.invalidFrame
        }
        guard Int(frame[8]) == 47 else {
            throw DecodeError.wrongRecordType(frame.count > 8 ? Int(frame[8]) : -1)
        }
        guard Int(frame[9]) == 18 else {
            throw DecodeError.unsupportedHistoricalVersion(frame.count > 9 ? Int(frame[9]) : -1)
        }
        guard frame[64] == 0x00 || frame[64] == 0x10 else {
            throw DecodeError.invalidFrame
        }
        return HistoricalV18StepCounterCandidate(
            stepMotionCounterCandidate: Int(frame[57]) | (Int(frame[58]) << 8),
            hardwareCounterCandidate: Int(frame[61]) | (Int(frame[62]) << 8),
            softwareOverrideCandidate: frame[64] == 0x10,
            stepCadenceRawCandidate: Int(frame[59]),
            activityClassRawCandidate: Int(frame[63])
        )
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
