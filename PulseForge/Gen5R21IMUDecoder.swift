import Foundation

/// Pure decoder for WHOOP Gen5 R21 IMU buffers carried by live 0x2B or historical/offload 0x2F frames.
/// Input is the complete CRC-validated transport frame, including its 8-byte header.
enum Gen5R21IMUDecoder {
    enum DecodeError: Error, Equatable {
        case invalidFrameLength(Int)
        case invalidInnerHeader
        case invalidSampleCounts(accelerometer: Int, gyroscope: Int)
    }

    static func decode(_ frame: [UInt8]) throws -> [WhoopIMUSample] {
        guard frame.count == 1244 else { throw DecodeError.invalidFrameLength(frame.count) }
        let inner = Array(frame[8..<1240])
        guard inner.count == 1232, (inner[0] == 0x2B || inner[0] == 0x2F), inner[1] == 21 else {
            throw DecodeError.invalidInnerHeader
        }

        func u16(_ offset: Int) -> Int {
            Int(inner[offset]) | (Int(inner[offset + 1]) << 8)
        }
        func i16(_ offset: Int) -> Int16 {
            Int16(bitPattern: UInt16(u16(offset)))
        }

        let accelCount = u16(16)
        let gyroCount = u16(622)
        guard (1...100).contains(accelCount), (1...100).contains(gyroCount) else {
            throw DecodeError.invalidSampleCounts(accelerometer: accelCount, gyroscope: gyroCount)
        }

        let pairedCount = min(accelCount, gyroCount)
        let unixSeconds = Double(
            UInt32(inner[7]) | (UInt32(inner[8]) << 8) |
            (UInt32(inner[9]) << 16) | (UInt32(inner[10]) << 24)
        )
        let frameTimestamp = unixSeconds + Double(u16(11)) / 32768.0
        let accelScale = 1.0 / 4096.0
        let gyroScale = 2000.0 / 32768.0

        var decodedSamples: [WhoopIMUSample] = []
        decodedSamples.reserveCapacity(pairedCount)
        for index in 0..<pairedCount {
            let sampleTimestamp = frameTimestamp + Double(index) / 100.0
            let ax = Double(i16(20 + 2 * index)) * accelScale
            let ay = Double(i16(220 + 2 * index)) * accelScale
            let az = Double(i16(420 + 2 * index)) * accelScale
            let gx = Double(i16(632 + 2 * index)) * gyroScale
            let gy = Double(i16(832 + 2 * index)) * gyroScale
            let gz = Double(i16(1032 + 2 * index)) * gyroScale
            let sample = WhoopIMUSample(
                timestamp: Date(timeIntervalSince1970: sampleTimestamp),
                accelerationXG: ax,
                accelerationYG: ay,
                accelerationZG: az,
                rotationXDPS: gx,
                rotationYDPS: gy,
                rotationZDPS: gz
            )
            decodedSamples.append(sample)
        }
        return decodedSamples
    }
}


/// WHOOP 5 packet-49 historical-offload metadata. Offsets are complete-frame absolute:
/// byte 10 is the metadata type; HISTORY_END echoes bytes 21...28 in command 23.
enum Gen5HistoricalMetadata: Equatable {
    case historyStart
    case historyEnd(endData: [UInt8], trim: UInt32)
    case historyComplete
    case other(UInt8)
    case invalid
}

enum Gen5HistoricalMetadataDecoder {
    static func decode(_ frame: [UInt8]) -> Gen5HistoricalMetadata {
        guard frame.count > 10, frame[8] == 49 else { return .invalid }
        switch frame[10] {
        case 1:
            return .historyStart
        case 2:
            guard frame.count >= 29 else { return .invalid }
            let endData = Array(frame[21..<29])
            let trim = UInt32(endData[0]) |
                (UInt32(endData[1]) << 8) |
                (UInt32(endData[2]) << 16) |
                (UInt32(endData[3]) << 24)
            return .historyEnd(endData: endData, trim: trim)
        case 3:
            return .historyComplete
        default:
            return .other(frame[10])
        }
    }
}
