import Foundation

/// Reassembles WHOOP Gen5 frames from notification byte streams.
/// This layer only finds frame boundaries; CRC validation and packet decoding
/// remain in WhoopBluetoothManager.
enum Whoop5FrameStreamAssembler {
    static let maximumFrameLength = 8_192

    enum Event {
        case frame(Data)
        case diagnostic(String)
    }

    struct Output {
        let events: [Event]
        let remainder: Data
        let expectedFrameLength: Int?
        let shouldDiagnoseUnframedChunk: Bool
    }

    static func append(_ chunk: Data, to pending: Data) -> Output {
        var buffer = pending

        if buffer.isEmpty {
            let incoming = [UInt8](chunk)
            let containsFrameMarker = incoming.count >= 2 &&
                (0..<(incoming.count - 1)).contains {
                    incoming[$0] == 0xAA && incoming[$0 + 1] == 0x01
                }
            guard incoming.first == 0xAA || containsFrameMarker else {
                // A notification may contain noise followed by the first byte
                // of a frame marker. Keep that byte for the next callback.
                let remainder = incoming.last == 0xAA ? Data([0xAA]) : Data()
                return Output(
                    events: [],
                    remainder: remainder,
                    expectedFrameLength: nil,
                    shouldDiagnoseUnframedChunk: true
                )
            }
        }

        buffer.append(chunk)
        var events: [Event] = []

        while !buffer.isEmpty {
            let bytes = [UInt8](buffer)
            if bytes.count < 2 { break }

            if bytes[0] != 0xAA || bytes[1] != 0x01 {
                if let sync = (0..<(bytes.count - 1)).first(where: {
                    bytes[$0] == 0xAA && bytes[$0 + 1] == 0x01
                }) {
                    buffer = Data(bytes[sync...])
                    continue
                }
                buffer = bytes.last == 0xAA ? Data([0xAA]) : Data()
                break
            }

            guard bytes.count >= 8 else { break }
            let declaredLength = Int(bytes[2]) | (Int(bytes[3]) << 8)
            let frameLength = 8 + declaredLength
            guard frameLength >= 12 && frameLength <= maximumFrameLength else {
                events.append(.diagnostic("WHOOP5 invalid declared frame length · \(frameLength)"))
                buffer.removeFirst()
                continue
            }

            guard bytes.count >= frameLength else { break }
            let completeFrame = Data(bytes.prefix(frameLength))
            buffer.removeFirst(frameLength)
            events.append(.frame(completeFrame))
        }

        if buffer.count > maximumFrameLength {
            buffer.removeAll()
            events.append(.diagnostic("WHOOP5 reassembly buffer exceeded safety limit · reset"))
        }

        let expectedFrameLength: Int?
        let remainderBytes = [UInt8](buffer)
        if remainderBytes.count >= 4,
           remainderBytes[0] == 0xAA,
           remainderBytes[1] == 0x01 {
            expectedFrameLength = 8 + Int(remainderBytes[2]) + (Int(remainderBytes[3]) << 8)
        } else {
            expectedFrameLength = nil
        }

        return Output(
            events: events,
            remainder: buffer,
            expectedFrameLength: expectedFrameLength,
            shouldDiagnoseUnframedChunk: false
        )
    }
}
