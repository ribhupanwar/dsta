import Foundation

/// WHOOP 5.0 RR interval decoder. Type-40 layout is cross-checked against
/// independent Gen5 protocol references and retained CRC-valid device captures.
///
/// Type-40: HR @16, count @17, RR UInt16 ticks @18+, unit 1/1024 second.
/// The caller must validate the outer WHOOP frame CRC before calling. Historical
/// v18 remains a separate candidate path and is not promoted by this decoder.
enum Whoop5RRDecoder {
    enum DecodeError: Error, Equatable {
        case invalidFrame
        case wrongRecordType(Int)
        case unsupportedHistoricalVersion(Int)
        case invalidIntervalCount(Int)
        case invalidIntervalValue(Int)
        case truncatedIntervals(expectedBytes: Int, availableBytes: Int)
    }

    /// WHOOP 5.0 Type-47 / revision-18 historical biometric fields.
    /// Timestamp/HR/RR fields are independently validated. Step-motion offsets
    /// below remain provisional pending original WHOOP binary cross-reference
    /// and device-correlated counter captures.
    struct HistoricalV18Biometrics: Equatable {
        let timestamp: Date
        let heartRateBPM: Int?
        let rawRRWords: [Int]
        let rrIntervalsMilliseconds: [Int]
        /// Gen5 v18 historical motion counter, UInt16 LE at frame offsets 57...58.
        /// OpenStrap independently maps these bytes in real CRC-valid Gen5 v18
        /// fixtures; exact producer semantics (steps vs. motion ticks) still
        /// require ground-truth correlation on this strap/firmware.
        let stepMotionCounter: Int
        /// Raw companion fields retained for diagnostics; their exact semantics remain provisional.
        let stepCadenceRaw: Int
        let activityClassRaw: Int
    }

    /// Type-40 raw RR words (ticks @18+, 1/1024 second). CRC must be validated first.
    static func decodeRealtimeCandidateRRWords(_ frame: [UInt8]) throws -> [Int] {
        guard frame.count >= 22, frame[0] == 0xAA, frame[1] == 0x01 else {
            throw DecodeError.invalidFrame
        }
        guard Int(frame[8]) == 40 else {
            throw DecodeError.wrongRecordType(frame.count > 8 ? Int(frame[8]) : -1)
        }
        return try decodeRawWords(frame, countOffset: 17, wordsOffset: 18)
    }

    /// Decode WHOOP 5.0 Type-40 RR ticks into integer milliseconds.
    /// Zero is padding; incomplete words and out-of-range intervals are rejected.
    /// Formula rounds to nearest ms: (ticks * 1000 + 512) / 1024.
    static func decodeRealtimeRRIntervalsMilliseconds(_ frame: [UInt8]) throws -> [Int] {
        let ticks = try decodeRealtimeCandidateRRWords(frame)
        var intervals: [Int] = []
        intervals.reserveCapacity(ticks.count)
        for value in ticks {
            if value == 0 { continue }
            let milliseconds = (value * 1000 + 512) / 1024
            guard (250...3000).contains(milliseconds) else {
                throw DecodeError.invalidIntervalValue(milliseconds)
            }
            intervals.append(milliseconds)
        }
        return intervals
    }

    /// WHOOP 5/MG Type-40 step tuple from the NOOP/OpenStrap R18 protocol map.
    /// The selected cumulative counter is u16le@57; hardware counter is u16le@61
    /// when software override is active (byte 64 == 0x10). Timestamp is Unix u32le@10.
    /// Cadence/activity are retained as raw diagnostics, never converted to steps.
    struct RealtimeStepCounter: Equatable {
        let timestamp: Date
        let selectedCounter: Int
        let hardwareCounter: Int
        let cadenceRaw: Int
        let activityRaw: Int
        let softwareOverride: Bool
    }

    static func decodeRealtimeStepCounter(_ frame: [UInt8]) throws -> RealtimeStepCounter {
        guard frame.count >= 65, frame[0] == 0xAA, frame[1] == 0x01,
              Int(frame[8]) == 40 else { throw DecodeError.invalidFrame }
        let seconds = UInt32(frame[10]) | (UInt32(frame[11]) << 8)
            | (UInt32(frame[12]) << 16) | (UInt32(frame[13]) << 24)
        guard seconds >= 1_577_836_800, seconds <= 4_102_444_800 else {
            throw DecodeError.invalidFrame
        }
        let selected = Int(frame[57]) | (Int(frame[58]) << 8)
        let hardware = Int(frame[61]) | (Int(frame[62]) << 8)
        let override = frame[64] == 0x10
        return RealtimeStepCounter(
            timestamp: Date(timeIntervalSince1970: TimeInterval(seconds)),
            selectedCounter: selected,
            hardwareCounter: hardware,
            cadenceRaw: Int(frame[59]),
            activityRaw: Int(frame[63]),
            softwareOverride: override
        )
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

    /// HISTORICAL_DATA v18 raw-word extraction (type 47):
    /// version @9, verified RR count @23, RR little-endian words @24.
    /// Values are retained unchanged; use decodeHistoricalV18Biometrics for
    /// validated millisecond intervals and the embedded physiological timestamp.
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

    /// Decode the Gen5 v18 motion counter independently from RR. OpenStrap
    /// maps the same frame bytes as a cumulative step/motion counter in real
    /// CRC-valid Gen5 v18 fixtures. Its exact producer semantics still need
    /// ground-truth validation on this strap/firmware. A malformed RR word
    /// must not discard an otherwise valid motion-counter sample.
    struct HistoricalV18StepCounter: Equatable {
        let timestamp: Date
        /// Counter selected by the band at bytes 57...58 (hardware normally,
        /// software when the override flag at byte 64 is active).
        let stepMotionCounter: Int
        /// Hardware counter retained at bytes 61...62 during software override.
        let hardwareCounter: Int
        let softwareOverride: Bool
        let stepCadenceRaw: Int
        let activityClassRaw: Int

        /// Keep the accumulated source on the hardware counter across override
        /// transitions, avoiding a false delta between software and hardware
        /// counter domains.
        var accumulationCounter: Int {
            softwareOverride ? hardwareCounter : stepMotionCounter
        }
    }

    static func decodeHistoricalV18StepCounter(_ frame: [UInt8]) throws -> HistoricalV18StepCounter {
        guard frame.count >= 65, frame[0] == 0xAA, frame[1] == 0x01 else {
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
        guard frame[64] == 0x00 || frame[64] == 0x10 else {
            throw DecodeError.invalidFrame
        }
        return HistoricalV18StepCounter(
            timestamp: Date(timeIntervalSince1970: TimeInterval(seconds)),
            stepMotionCounter: Int(frame[57]) | (Int(frame[58]) << 8),
            hardwareCounter: Int(frame[61]) | (Int(frame[62]) << 8),
            softwareOverride: frame[64] == 0x10,
            stepCadenceRaw: Int(frame[59]),
            activityClassRaw: Int(frame[63])
        )
    }

    /// Decode hardware-verified WHOOP 5.0 Type-47 revision-18 biometrics.
    /// Caller must validate the complete outer frame CRC before calling.
    /// RR words are already milliseconds; unlike Type-40 ticks, do NOT scale by 1000/1024.
    static func decodeHistoricalV18Biometrics(_ frame: [UInt8]) throws -> HistoricalV18Biometrics {
        guard frame.count >= 64, frame[0] == 0xAA, frame[1] == 0x01 else {
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

        let rawHeartRate = Int(frame[22])
        let heartRate: Int?
        if rawHeartRate == 0 {
            heartRate = nil // WHOOP uses zero for an unavailable/off-wrist HR sample.
        } else {
            guard (25...240).contains(rawHeartRate) else {
                throw DecodeError.invalidIntervalValue(rawHeartRate)
            }
            heartRate = rawHeartRate
        }

        let words = try decodeHistoricalV18CandidateRRWords(frame)
        let intervals = words.filter { $0 > 0 }
        for value in intervals where !(250...3000).contains(value) {
            throw DecodeError.invalidIntervalValue(value)
        }

        let stepCounter = try decodeHistoricalV18StepCounter(frame)
        return HistoricalV18Biometrics(
            timestamp: Date(timeIntervalSince1970: TimeInterval(seconds)),
            heartRateBPM: heartRate,
            rawRRWords: words,
            rrIntervalsMilliseconds: intervals,
            stepMotionCounter: stepCounter.stepMotionCounter,
            stepCadenceRaw: stepCounter.stepCadenceRaw,
            activityClassRaw: stepCounter.activityClassRaw
        )
    }

    /// Legacy candidate-only timestamp helper retained for forensic comparisons.
    /// Production code must use decodeHistoricalV18Biometrics, which validates
    /// the full v18 layout and returns the timestamp with its HR/RR fields.
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

    /// Legacy candidate-only HR helper retained for forensic comparisons.
    /// Production code must use decodeHistoricalV18Biometrics.
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
