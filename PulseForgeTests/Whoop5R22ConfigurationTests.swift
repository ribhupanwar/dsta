import XCTest
@testable import PulseForge

final class Whoop5R22ConfigurationTests: XCTestCase {
    func testOfficialEnableSequenceContainsSixteenOrderedFlags() {
        let flags = Whoop5R22Configuration.officialEnableSequence
        XCTAssertEqual(flags.count, 16)
        XCTAssertEqual(flags.first?.name, "enable_r22_packets")
        XCTAssertEqual(flags.last?.name, "enable_sig12")
        XCTAssertEqual(flags.map(\.value), [
            0x32, 0x32, 0x32, 0x31, 0x32, 0x32, 0x32, 0x32,
            0x32, 0x32, 0x32, 0x32, 0x31, 0x32, 0x32, 0x31
        ])
    }

    func testPayloadIsFortyBytesWithNulPaddedKeyAndValueAtOffset32() {
        let flag = Whoop5R22Configuration.Flag(name: "enable_r22_packets", value: 0x32)
        let body = Whoop5R22Configuration.payloadBody(for: flag)
        XCTAssertEqual(body.count, 40)
        XCTAssertEqual(Array(body.prefix(18)), Array("enable_r22_packets".utf8))
        XCTAssertTrue(body[18..<32].allSatisfy { $0 == 0 })
        XCTAssertEqual(body[32], 0x32)
        XCTAssertTrue(body[33..<40].allSatisfy { $0 == 0 })
    }

    func testCommandFrameUsesSetConfigOpcodeAndExpectedEnvelope() {
        let flag = Whoop5R22Configuration.Flag(name: "enable_r22_packets", value: 0x32)
        let frame = Whoop5R22Configuration.commandFrame(for: flag, sequence: 0x2A)
        XCTAssertEqual(Array(frame.prefix(8)), [0xAA, 0x01, 0x30, 0x00, 0x00, 0x01, frame[6], frame[7]])
        XCTAssertEqual(Array(frame[8..<12]), [0x23, 0x2A, 0x78, 0x01])
        XCTAssertEqual(Array(frame[12..<52]), Whoop5R22Configuration.payloadBody(for: flag))
        XCTAssertEqual(frame.count, 56)
    }

    func testSequenceNumbersWrapAtUInt8Boundary() {
        let frames = Whoop5R22Configuration.enableFrames(firstSequence: 250)
        XCTAssertEqual(frames.count, 16)
        XCTAssertEqual(frames[0][9], 250)
        XCTAssertEqual(frames[5][9], 255)
        XCTAssertEqual(frames[6][9], 0)
        XCTAssertEqual(frames[15][9], 9)
    }
}
