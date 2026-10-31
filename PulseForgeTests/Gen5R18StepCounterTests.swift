import XCTest
@testable import PulseForge

final class Gen5R18StepCounterTests: XCTestCase {
    func testDecodesR18SelectedAndHardwareCounters() {
        var frame = Data(repeating: 0, count: 124)
        frame[8] = 47
        frame[9] = 18
        frame[57] = 0x34
        frame[58] = 0x12
        frame[59] = 0x07
        frame[60] = 0x00
        frame[61] = 0x78
        frame[62] = 0x56
        frame[63] = 1
        frame[64] = 0x10

        let record = Gen5R18StepRecord.decode(frame)
        XCTAssertEqual(record?.selectedCounter, 0x1234)
        XCTAssertEqual(record?.cadenceRaw, 7)
        XCTAssertEqual(record?.hardwareCounter, 0x5678)
        XCTAssertEqual(record?.activityLabel, "walk")
        XCTAssertEqual(record?.softwareOverrideActive, true)
    }

    func testRejectsWrongPacketOrLayout() {
        var frame = Data(repeating: 0, count: 124)
        frame[8] = 47
        frame[9] = 21
        XCTAssertNil(Gen5R18StepRecord.decode(frame))
        frame[9] = 18
        frame[8] = 43
        XCTAssertNil(Gen5R18StepRecord.decode(frame))
    }

    func testDeltaDoesNotInventResetOrRollover() {
        var tracker = Gen5StepCounterDelta()
        XCTAssertNil(tracker.observe(23))
        XCTAssertEqual(tracker.observe(30), 7)
        XCTAssertNil(tracker.observe(4))
        XCTAssertEqual(tracker.observe(9), 5)
    }
}
