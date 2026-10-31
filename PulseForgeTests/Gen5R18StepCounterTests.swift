import XCTest
@testable import PulseForge

final class Gen5R18StepCounterTests: XCTestCase {
    private func makeR18Frame() -> Data {
        var frame = Data(repeating: 0, count: 124)
        frame[8] = 47
        frame[9] = 18
        return frame
    }

    private func sealR18CRC(_ frame: inout Data) {
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
        frame[120] = UInt8(crc & 0xFF)
        frame[121] = UInt8((crc >> 8) & 0xFF)
        frame[122] = UInt8((crc >> 16) & 0xFF)
        frame[123] = UInt8((crc >> 24) & 0xFF)
    }

    func testDecodesR18SelectedAndHardwareCounters() {
        var frame = makeR18Frame()
        frame[57] = 0x34
        frame[58] = 0x12
        frame[59] = 0x07
        frame[60] = 0x00
        frame[61] = 0x78
        frame[62] = 0x56
        frame[63] = 1
        frame[64] = 0x10
        sealR18CRC(&frame)

        let record = Gen5R18StepRecord.decode(frame)
        XCTAssertEqual(record?.selectedCounter, 0x1234)
        XCTAssertEqual(record?.cadenceRaw, 7)
        XCTAssertEqual(record?.hardwareCounter, 0x5678)
        XCTAssertEqual(record?.activityLabel, "walk")
        XCTAssertEqual(record?.softwareOverrideActive, true)
    }

    func testRejectsWrongPacketOrLayoutAndInvalidCRC() {
        var frame = makeR18Frame()
        sealR18CRC(&frame)
        XCTAssertNotNil(Gen5R18StepRecord.decode(frame))

        frame[9] = 21
        XCTAssertNil(Gen5R18StepRecord.decode(frame))
        frame[9] = 18
        frame[8] = 43
        XCTAssertNil(Gen5R18StepRecord.decode(frame))

        frame = makeR18Frame()
        frame[57] = 1
        sealR18CRC(&frame)
        frame[57] = 2 // invalidate the inner record CRC
        XCTAssertNil(Gen5R18StepRecord.decode(frame))

        frame = makeR18Frame()
        XCTAssertNil(Gen5R18StepRecord.decode(Data(frame.prefix(82))))
    }

    func testDeltaDoesNotInventResetOrRollover() {
        var tracker = Gen5StepCounterDelta()
        XCTAssertNil(tracker.observe(23))
        XCTAssertEqual(tracker.observe(30), 7)
        XCTAssertNil(tracker.observe(4))
        XCTAssertEqual(tracker.observe(9), 5)
    }
}
