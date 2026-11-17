import Foundation

/// Shared WHOOP Gen5 outer-frame validator used by live BLE routing and
/// archive migration. A decoded field is never promoted to verified physiology
/// unless both the header CRC16-Modbus and padded-inner CRC32 pass.
enum Whoop5FrameValidator {
    static func isValid(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 12, bytes[0] == 0xAA, bytes[1] == 0x01 else {
            return false
        }
        let declaredLength = Int(bytes[2]) | (Int(bytes[3]) << 8)
        guard declaredLength >= 4, 8 + declaredLength == bytes.count else {
            return false
        }

        let storedHeaderCRC = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
        guard crc16Modbus(Array(bytes[0..<6])) == storedHeaderCRC else {
            return false
        }

        let payloadEnd = bytes.count - 4
        let paddedInner = Array(bytes[8..<payloadEnd])
        let storedPayloadCRC = UInt32(bytes[payloadEnd])
            | (UInt32(bytes[payloadEnd + 1]) << 8)
            | (UInt32(bytes[payloadEnd + 2]) << 16)
            | (UInt32(bytes[payloadEnd + 3]) << 24)
        return crc32(paddedInner) == storedPayloadCRC
    }

    static func crc16Modbus(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xA001 : (crc >> 1)
            }
        }
        return crc
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
