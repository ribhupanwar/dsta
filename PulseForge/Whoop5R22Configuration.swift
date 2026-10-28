import Foundation

/// Byte-exact builder for WHOOP 5.0/MG R22 feature-flag writes.
/// This type performs no Bluetooth I/O: these flags persist on the strap and
/// must only be sent after an explicit user opt-in and serialized ACK handling.
enum Whoop5R22Configuration {
    struct Flag: Equatable {
        let name: String
        let value: UInt8
    }

    static let opcode: UInt8 = 0x78

    /// Ordered values transcribed from NOOP's hardware-captured official-app sequence.
    static let officialEnableSequence: [Flag] = [
        Flag(name: "enable_r22_packets", value: 0x32),
        Flag(name: "enable_r22_v2_packets", value: 0x32),
        Flag(name: "enable_r22_v3_packets", value: 0x32),
        Flag(name: "enable_r22_v4_packets", value: 0x31),
        Flag(name: "enable_r22_v5_packets", value: 0x32),
        Flag(name: "enable_r22_v6_packets", value: 0x32),
        Flag(name: "enable_r22_v8_packets", value: 0x32),
        Flag(name: "make_hrfm_visible", value: 0x32),
        Flag(name: "disable_pip_r26_packets", value: 0x32),
        Flag(name: "wear_detect_bias", value: 0x32),
        Flag(name: "hr_ch_switching", value: 0x32),
        Flag(name: "ir_hw_switching", value: 0x32),
        Flag(name: "enable_passive_strap_fit_gen5", value: 0x31),
        Flag(name: "enable_sig11_during_sleep", value: 0x32),
        Flag(name: "dorset_inhibit_wpt", value: 0x32),
        Flag(name: "enable_sig12", value: 0x31)
    ]

    /// 40-byte SET_CONFIG body: ASCII key, NUL-padded to 32 bytes,
    /// value byte at offset 32, then seven trailing zero bytes.
    static func payloadBody(for flag: Flag) -> [UInt8] {
        let key = Array(flag.name.utf8)
        precondition(!key.isEmpty && key.count <= 32, "R22 key must fit the 32-byte field")
        var body = [UInt8](repeating: 0, count: 40)
        body.replaceSubrange(0..<key.count, with: key)
        body[32] = flag.value
        return body
    }

    /// Full puffin SET_CONFIG frame. Caller must write with response and await
    /// each command response before sending the next frame.
    static func commandFrame(for flag: Flag, sequence: UInt8) -> [UInt8] {
        var inner = [UInt8]([0x23, sequence, opcode, 0x01] + payloadBody(for: flag))
        while inner.count % 4 != 0 { inner.append(0) }
        let declared = UInt16(inner.count + 4)
        var header: [UInt8] = [0xAA, 0x01, UInt8(declared & 0xFF),
                               UInt8((declared >> 8) & 0xFF), 0x00, 0x01]
        let headerCRC = crc16Modbus(header)
        header.append(UInt8(headerCRC & 0xFF))
        header.append(UInt8((headerCRC >> 8) & 0xFF))
        let payloadCRC = crc32(inner)
        let tail: [UInt8] = [UInt8(payloadCRC & 0xFF), UInt8((payloadCRC >> 8) & 0xFF),
                             UInt8((payloadCRC >> 16) & 0xFF), UInt8((payloadCRC >> 24) & 0xFF)]
        return header + inner + tail
    }

    static func enableFrames(firstSequence: UInt8) -> [[UInt8]] {
        officialEnableSequence.enumerated().map { index, flag in
            commandFrame(for: flag, sequence: firstSequence &+ UInt8(index))
        }
    }

    private static func crc16Modbus(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1 }
        }
        return crc ^ 0xFFFFFFFF
    }
}
