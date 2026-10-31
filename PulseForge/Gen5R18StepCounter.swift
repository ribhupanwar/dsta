import Foundation

/// Decodes WHOOP 5/MG R18 biometric-summary step-source fields from a
/// complete, reassembled, outer-CRC-validated type-47 frame.
/// R18 is exactly 124 bytes and also carries its own CRC32 at bytes 120...123.
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

    /// The @61 hardware source is meaningful only while the software
    /// counter override is active. Preserve raw zero separately.
    var hardwareCounterWhenOverrideActive: UInt16? {
        softwareOverrideActive ? hardwareCounter : nil
    }

    static func decode(_ frame: Data) -> Gen5R18StepRecord? {
        // Absolute offsets in the complete WHOOP 5/MG format-1 frame.
        // Validate the exact R18 shape and its record CRC independently of
        // the transport-envelope CRC checked by WhoopBluetoothManager.
        guard frame.count == 124,
              frame[8] == 47,       // HISTORICAL_DATA
              frame[9] == 18,       // R18 biometric summary
              hasValidRecordCRC(frame) else {
            return nil
        }

        func u16le(_ offset: Int) -> UInt16 {
            UInt16(frame[offset]) | (UInt16(frame[offset + 1]) << 8)
        }

        return Gen5R18StepRecord(
            selectedCounter: u16le(57),
            cadenceRaw: u16le(59),
            hardwareCounter: u16le(61),
            activityRaw: frame[63],
            softwareOverrideActive: frame[64] == 0x10
        )
    }

    private static func hasValidRecordCRC(_ frame: Data) -> Bool {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in frame[8..<120] {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1
                    ? (crc >> 1) ^ 0xEDB8_8320
                    : (crc >> 1)
            }
        }
        crc ^= 0xFFFF_FFFF
        let stored = UInt32(frame[120])
            | (UInt32(frame[121]) << 8)
            | (UInt32(frame[122]) << 16)
            | (UInt32(frame[123]) << 24)
        return crc == stored
    }
}

/// Stateful delta helper for diagnostics only. It does not infer midnight
/// resets or advertise a daily total. A decrease is reported as a reset/
/// unknown discontinuity rather than guessed rollover.
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
