import XCTest
@testable import PulseForge

final class Whoop5StepLedgerTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(_ seconds: TimeInterval, _ counter: UInt16,
                        _ activity: UInt8? = 1, override: Bool = false,
                        hardware: UInt16? = nil) -> Whoop5StepSample {
        Whoop5StepSample(timestamp: epoch.addingTimeInterval(seconds),
                         selectedCounter: counter, cadenceRaw: 0,
                         hardwareCounter: hardware, activityClass: activity,
                         softwareOverrideActive: override)
    }

    func testCountsWalkAndRunCounterDeltas() {
        let result = Whoop5StepLedger.count(samples: [
            sample(0, 100, 1), sample(10, 120, 1), sample(20, 150, 2)
        ])
        XCTAssertEqual(result.acceptedTicks, 50)
    }

    func testRejectsStillAndUnknownActivityClasses() {
        let result = Whoop5StepLedger.count(samples: [
            sample(0, 100, 1), sample(10, 110, 0), sample(20, 120, nil)
        ])
        XCTAssertEqual(result.acceptedTicks, 0)
        XCTAssertEqual(result.rejectedStillOrUnknownTicks, 20)
    }

    func testCounterRolloverUsesUnsignedSixteenBitDelta() {
        let result = Whoop5StepLedger.count(samples: [
            sample(0, 65_530), sample(10, 5)
        ])
        XCTAssertEqual(result.acceptedTicks, 11)
    }

    func testRejectsImplausibleLargeDelta() {
        let result = Whoop5StepLedger.count(samples: [
            sample(0, 100), sample(1, 700)
        ])
        XCTAssertEqual(result.acceptedTicks, 0)
        XCTAssertEqual(result.rejectedImplausibleTicks, 600)
    }

    func testDoesNotBridgeCounterSourceSwitch() {
        let result = Whoop5StepLedger.count(samples: [
            sample(0, 100, 1, override: false),
            sample(10, 150, 1, override: true, hardware: 140)
        ])
        XCTAssertEqual(result.acceptedTicks, 0)
        XCTAssertEqual(result.rejectedSourceSwitches, 1)
    }

    func testDoesNotBridgeCalendarDayBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.startOfDay(for: epoch).addingTimeInterval(86_400)
        let before = Whoop5StepSample(timestamp: midnight.addingTimeInterval(-5),
            selectedCounter: 100, cadenceRaw: 0, hardwareCounter: nil,
            activityClass: 1, softwareOverrideActive: false)
        let after = Whoop5StepSample(timestamp: midnight.addingTimeInterval(5),
            selectedCounter: 150, cadenceRaw: 0, hardwareCounter: nil,
            activityClass: 1, softwareOverrideActive: false)
        let result = Whoop5StepLedger.count(samples: [before, after], calendar: calendar)
        XCTAssertEqual(result.acceptedTicks, 0)
    }

    func testConfirmedSleepIntervalRejectsTicksWithoutLosingAudit() {
        let asleep = DateInterval(start: epoch.addingTimeInterval(2),
                                  end: epoch.addingTimeInterval(8))
        let result = Whoop5StepLedger.count(samples: [
            sample(0, 100), sample(10, 110)
        ], confirmedAsleepIntervals: [asleep])
        XCTAssertEqual(result.acceptedTicks, 0)
        XCTAssertEqual(result.rejectedSleepTicks, 10)
    }

    func testNoActivityLabelsUsesLegacyCounterFallback() {
        let result = Whoop5StepLedger.count(samples: [
            sample(0, 10, nil), sample(10, 20, nil)
        ])
        XCTAssertEqual(result.acceptedTicks, 10)
    }

    func testDecoderReadsSelectedAndHardwareCounterAndOverrideFlag() throws {
        var frame = [UInt8](repeating: 0, count: 80)
        frame[0] = 0xAA; frame[1] = 0x01; frame[8] = 47; frame[9] = 18
        frame[57] = 0x34; frame[58] = 0x12 // selected = 0x1234
        frame[59] = 88
        frame[61] = 0x78; frame[62] = 0x56 // hardware = 0x5678
        frame[63] = 2
        frame[64] = 0x10
        let decoded = try Whoop5StepFrameDecoder.decodeHistoricalV18(frame, timestamp: epoch)
        XCTAssertEqual(decoded.selectedCounter, 0x1234)
        XCTAssertEqual(decoded.hardwareCounter, 0x5678)
        XCTAssertEqual(decoded.cadenceRaw, 88)
        XCTAssertEqual(decoded.activityClass, 2)
        XCTAssertTrue(decoded.softwareOverrideActive)
    }

    func testDecoderDoesNotExposeHardwareCounterWithoutOverride() throws {
        var frame = [UInt8](repeating: 0, count: 80)
        frame[0] = 0xAA; frame[1] = 0x01; frame[8] = 47; frame[9] = 18
        frame[57] = 9; frame[61] = 42; frame[63] = 1
        let decoded = try Whoop5StepFrameDecoder.decodeHistoricalV18(frame, timestamp: epoch)
        XCTAssertNil(decoded.hardwareCounter)
        XCTAssertFalse(decoded.softwareOverrideActive)
    }

    func testDecoderRejectsType40RealtimePacket() {
        var frame = [UInt8](repeating: 0, count: 80)
        frame[0] = 0xAA; frame[1] = 0x01; frame[8] = 40; frame[9] = 18
        XCTAssertThrowsError(try Whoop5StepFrameDecoder.decodeHistoricalV18(frame, timestamp: epoch))
    }
}
