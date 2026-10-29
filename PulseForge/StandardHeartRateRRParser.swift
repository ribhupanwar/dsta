import Foundation

/// Parses the optional RR-Interval field in the Bluetooth SIG Heart Rate Measurement
/// characteristic (0x2A37). RR values are unsigned 1/1024-second units.
enum StandardHeartRateRRParser {
    static func parseMilliseconds(_ data: Data) -> [Int] {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return [] }
        let flags = bytes[0]
        guard (flags & 0x10) != 0 else { return [] }

        var offset = 1
        if (flags & 0x01) != 0 {
            guard bytes.count >= offset + 2 else { return [] }
            offset += 2
        } else {
            guard bytes.count >= offset + 1 else { return [] }
            offset += 1
        }

        // Energy Expended (kJ) precedes RR values when bit 3 is set.
        if (flags & 0x08) != 0 {
            guard bytes.count >= offset + 2 else { return [] }
            offset += 2
        }

        guard offset < bytes.count, (bytes.count - offset).isMultiple(of: 2) else { return [] }
        var intervals: [Int] = []
        while offset + 1 < bytes.count {
            let raw = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            let milliseconds = Int((Double(raw) * 1000.0 / 1024.0).rounded())
            guard (250...3000).contains(milliseconds) else { return [] }
            intervals.append(milliseconds)
            offset += 2
        }
        return intervals
    }
}
