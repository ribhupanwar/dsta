import XCTest
@testable import PulseForge

final class Gen5R21IMUDecoderTests: XCTestCase {
    private func makeFrame(innerType: UInt8 = 0x2B, accelCount: Int = 2, gyroCount: Int = 2) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: 1244)
        let inner = 8
        frame[inner] = innerType
        frame[inner + 1] = 21
        let epoch: UInt32 = 1_700_000_000
        for i in 0..<4 { frame[inner + 7 + i] = UInt8((epoch >> (8 * i)) & 0xFF) }
        frame[inner + 11] = 0
        frame[inner + 12] = 0
        putU16(accelCount, at: inner + 16, in: &frame)
        putU16(gyroCount, at: inner + 622, in: &frame)
        putI16(4096, at: inner + 20, in: &frame)
        putI16(-2048, at: inner + 220, in: &frame)
        putI16(8192, at: inner + 420, in: &frame)
        putI16(16384, at: inner + 632, in: &frame)
        putI16(-8192, at: inner + 832, in: &frame)
        putI16(32767, at: inner + 1032, in: &frame)
        return frame
    }

    private func putU16(_ value: Int, at offset: Int, in bytes: inout [UInt8]) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private func putI16(_ value: Int16, at offset: Int, in bytes: inout [UInt8]) {
        putU16(Int(UInt16(bitPattern: value)), at: offset, in: &bytes)
    }

    func testDecodesAxesAndCalibrationScales() throws {
        let samples = try Gen5R21IMUDecoder.decode(makeFrame())
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].accelerationXG, 1.0, accuracy: 0.000001)
        XCTAssertEqual(samples[0].accelerationYG, -0.5, accuracy: 0.000001)
        XCTAssertEqual(samples[0].accelerationZG, 2.0, accuracy: 0.000001)
        XCTAssertEqual(samples[0].rotationXDPS, 1000.0, accuracy: 0.000001)
        XCTAssertEqual(samples[0].rotationYDPS, -500.0, accuracy: 0.000001)
        XCTAssertEqual(samples[0].rotationZDPS, 2000.0 * 32767.0 / 32768.0, accuracy: 0.000001)
    }

    func testDecodesHistoricalR21BufferType47() throws {
        let samples = try Gen5R21IMUDecoder.decode(makeFrame(innerType: 0x2F))
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].accelerationXG, 1.0, accuracy: 0.000001)
    }

    func testUsesHundredHertzSampleSpacing() throws {
        let samples = try Gen5R21IMUDecoder.decode(makeFrame())
        XCTAssertEqual(samples[1].timestamp.timeIntervalSince(samples[0].timestamp), 0.01, accuracy: 0.000001)
    }

    func testUsesR21TimestampFractionAtFrameOffset19() throws {
        var frame = makeFrame(innerType: 0x2F)
        putU16(16_384, at: 19, in: &frame) // 0.5 seconds at 1/32768-second units
        let samples = try Gen5R21IMUDecoder.decode(frame)
        XCTAssertEqual(samples[0].timestamp.timeIntervalSince1970, 1_700_000_000.5, accuracy: 0.000001)
    }

    func testPairsOnlyCommonAccelerometerAndGyroscopeSamples() throws {
        XCTAssertEqual(try Gen5R21IMUDecoder.decode(makeFrame(accelCount: 1, gyroCount: 2)).count, 1)
    }

    func testRejectsWrongFrameLength() {
        XCTAssertThrowsError(try Gen5R21IMUDecoder.decode([UInt8](repeating: 0, count: 1243)))
    }

    func testRejectsWrongRevision() {
        var frame = makeFrame()
        frame[9] = 20
        XCTAssertThrowsError(try Gen5R21IMUDecoder.decode(frame))
    }

    func testRejectsInvalidCounts() {
        XCTAssertThrowsError(try Gen5R21IMUDecoder.decode(makeFrame(accelCount: 0, gyroCount: 1)))
        XCTAssertThrowsError(try Gen5R21IMUDecoder.decode(makeFrame(accelCount: 101, gyroCount: 1)))
    }
}
