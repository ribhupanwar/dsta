import XCTest
@testable import PulseForge

final class StandardHeartRateRRParserTests: XCTestCase {
    func testParsesRRIntervalsIn1024HzUnits() {
        // Flags: RR present. HR 70 bpm. RR 1024 and 1008 ticks.
        let data = Data([0x10, 70, 0x00, 0x04, 0xF0, 0x03])
        XCTAssertEqual(StandardHeartRateRRParser.parseMilliseconds(data), [1000, 984])
    }

    func testSkipsEnergyExpendedBeforeRRValues() {
        // Flags: Energy Expended + RR present. HR 70, energy 12 kJ, RR 1024 ticks.
        let data = Data([0x18, 70, 12, 0, 0, 4])
        XCTAssertEqual(StandardHeartRateRRParser.parseMilliseconds(data), [1000])
    }

    func testSupportsUInt16HeartRateBeforeRRValues() {
        // Flags: 16-bit HR + RR present. HR 300, RR 1024 ticks.
        let data = Data([0x11, 44, 1, 0, 4])
        XCTAssertEqual(StandardHeartRateRRParser.parseMilliseconds(data), [1000])
    }

    func testReturnsEmptyWhenRRFlagIsAbsentOrPayloadIsTruncated() {
        XCTAssertEqual(StandardHeartRateRRParser.parseMilliseconds(Data([0x00, 70])), [])
        XCTAssertEqual(StandardHeartRateRRParser.parseMilliseconds(Data([0x10, 70, 0x00])), [])
    }

    func testRejectsImplausibleRRValuesWithoutReturningPartialData() {
        let data = Data([0x10, 70, 0x00, 0x00, 0x88, 0x13])
        XCTAssertEqual(StandardHeartRateRRParser.parseMilliseconds(data), [])
    }
}
