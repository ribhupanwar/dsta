import Foundation

/// Decodes the WHOOP 5/MG R18 step-source fields from a fully reassembled,
/// CRC-validated type-47 historical frame. This deliberately exposes raw
/// counters; it does not claim that either counter equals the app's cycle total.
struct Gen5R18StepRecord: Equatable {
    let selectedCounter: UInt16
    let cadenceRaw: UInt16
    let hardwareCounter: UInt16
    let activityRaw: UInt8
    let softwareOverrideActive: Bool

    var activityLabel: String {
        switch activityRaw {
        case 0: return "still"
        case 1: return "walk"
        case 2: return "run"
        default: return "unknown"
        }
    }

    static func decode(_ frame: Data) -> Gen5R18StepRecord? {
        // Absolute offsets in the complete WHOOP 5/MG format-1 frame.
        // Caller must reassemble fragments and validate envelope CRCs first.
        guard frame.count >= 82,
              frame[8] == 47,       // HISTORICAL_DATA
              frame[9] == 18 else { // R18 biometric summary
            return nil
        }

        func u16le(_ offset: Int) -> UInt16 {
            UInt16(frame[offset]) | (UInt16(frame[offset + 1]) << 8)
        }

        let flags = frame[64]
        return Gen5R18StepRecord(
            selectedCounter: u16le(57),
            cadenceRaw: u16le(59),
            hardwareCounter: u16le(61),
            activityRaw: frame[63],
            softwareOverrideActive: (flags & 0x10) != 0
        )
    }
}

/// Stateful delta helper for diagnostics only. It does not infer midnight
/// resets or advertise a daily total. A decrease is reported as a reset/
unknown discontinuity rather than guessed rollover.
struct Gen5StepCounterDelta {
    private(set) var previous: UInt16?

    mutating func observe(_ current: UInt16) -> Int? {
        defer { previous = current }
        guard let previous else { return nil }
        guard current >= previous else { return nil }
        return Int(current - previous)
    }

    mutating func reset() {
        previous = nil
    }
}
