import XCTest
@testable import PulseForge

final class Whoop5FrameStreamAssemblerTests: XCTestCase {
    private let captureHex = "AA01740001003FB12F128037170700FA9AE36A9939004B015F030000000000000000992C074B0000FF4034793C00005CBF71FD30BEC3B5FF3E6C01F200000000000000000031013B01F90C900A010C060C10000000000000000000000000000000000000000000000100A1B724230000001A30A8C00000002AC67557"

    private var capture: Data {
        Data(stride(from: 0, to: captureHex.count, by: 2).map { offset in
            let start = captureHex.index(captureHex.startIndex, offsetBy: offset)
            let end = captureHex.index(start, offsetBy: 2)
            return UInt8(captureHex[start..<end], radix: 16)!
        })
    }

    private func frames(in events: [Whoop5FrameStreamAssembler.Event]) -> [Data] {
        events.compactMap {
            if case .frame(let data) = $0 { return data }
            return nil
        }
    }

    private func diagnostics(in events: [Whoop5FrameStreamAssembler.Event]) -> [String] {
        events.compactMap {
            if case .diagnostic(let message) = $0 { return message }
            return nil
        }
    }

    func testPreservesTrailingFrameMarkerAfterUnframedNoise() {
        let first = Whoop5FrameStreamAssembler.append(
            Data([0x10, 0x20, 0xAA]),
            to: Data()
        )
        XCTAssertTrue(first.shouldDiagnoseUnframedChunk)
        XCTAssertEqual(first.remainder, Data([0xAA]))

        let second = Whoop5FrameStreamAssembler.append(
            Data(capture.dropFirst()),
            to: first.remainder
        )
        XCTAssertFalse(second.shouldDiagnoseUnframedChunk)
        XCTAssertEqual(frames(in: second.events), [capture])
        XCTAssertTrue(second.remainder.isEmpty)
    }

    func testPreservesMarkerSplitAcrossNotifications() {
        let first = Whoop5FrameStreamAssembler.append(Data([0xAA]), to: Data())
        XCTAssertEqual(first.remainder, Data([0xAA]))

        let second = Whoop5FrameStreamAssembler.append(
            Data(capture.dropFirst()),
            to: first.remainder
        )
        XCTAssertEqual(frames(in: second.events), [capture])
        XCTAssertTrue(second.remainder.isEmpty)
    }

    func testReassemblesFrameSplitAcrossPayload() {
        let split = 23
        let first = Whoop5FrameStreamAssembler.append(
            Data(capture.prefix(split)),
            to: Data()
        )
        XCTAssertTrue(frames(in: first.events).isEmpty)
        XCTAssertEqual(first.remainder, Data(capture.prefix(split)))
        XCTAssertEqual(first.expectedFrameLength, capture.count)

        let second = Whoop5FrameStreamAssembler.append(
            Data(capture.dropFirst(split)),
            to: first.remainder
        )
        XCTAssertEqual(frames(in: second.events), [capture])
        XCTAssertTrue(second.remainder.isEmpty)
    }

    func testExtractsMultipleFramesFromOneNotification() {
        var combined = capture
        combined.append(capture)

        let result = Whoop5FrameStreamAssembler.append(combined, to: Data())
        XCTAssertEqual(frames(in: result.events), [capture, capture])
        XCTAssertTrue(result.remainder.isEmpty)
    }

    func testResynchronizesAfterInvalidDeclaredLength() {
        var combined = Data([0xAA, 0x01, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00])
        combined.append(capture)

        let result = Whoop5FrameStreamAssembler.append(combined, to: Data())
        XCTAssertEqual(frames(in: result.events), [capture])
        XCTAssertEqual(diagnostics(in: result.events), [
            "WHOOP5 invalid declared frame length · 65543"
        ])
        XCTAssertTrue(result.remainder.isEmpty)
    }

    func testUnframedNoiseWithoutTrailingMarkerIsNotBuffered() {
        let result = Whoop5FrameStreamAssembler.append(
            Data([0x10, 0x20, 0x30]),
            to: Data()
        )
        XCTAssertTrue(result.shouldDiagnoseUnframedChunk)
        XCTAssertTrue(result.remainder.isEmpty)
    }
}
