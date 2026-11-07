import XCTest
@testable import PulseForge

final class Whoop5RRDecoderTests: XCTestCase {
    private func bytes(_ hex: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return result
    }

    func testExtractsCandidateRealtimeRRWordsWithoutUnitConversion() throws {
        // NOOP-sourced type-40 fixture only; offsets and units are not WHOOP-verified.
        let frame = bytes("aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc")
        XCTAssertEqual(try Whoop5RRDecoder.decodeRealtimeCandidateRRWords(frame), [603, 587])
    }

    func testDecodesWHOOPDeviceCorrelatedRealtimeHRAndRR() throws {
        // Exact 32-byte CRC-valid frame from the user's WHOOP 5.0 capture.
        let frame = bytes("AA011800010022E12802ECFFE36A8F4257016F04000000000000010023BAA03D")
        XCTAssertEqual(try Whoop5RRDecoder.decodeRealtimeHeartRate(frame), 87)
        XCTAssertEqual(try Whoop5RRDecoder.decodeRealtimeCandidateRRWords(frame), [1135])
    }

    func testLatestType40CapturePreservesRawCandidateWordsWithoutUnitConversion() throws {
        let frame = bytes("AA011800010022E12802462CE46A51586002BD031D020000000001006ABABCD5")
        XCTAssertEqual(try Whoop5RRDecoder.decodeRealtimeCandidateRRWords(frame), [957, 541])
    }
    func testRealtimeCandidateWordsPreserveZeroPadding() throws {
        var frame = bytes("AA011800010022E128029EA0266AAE4762025B024B020000000001005ED515DC")
        frame[18] = 0
        frame[19] = 0
        XCTAssertEqual(try Whoop5RRDecoder.decodeRealtimeCandidateRRWords(frame), [0, 587])
    }
    func testRealtimeMotionFieldsRemainCandidateOnlyWithoutTimestamp() throws {
        var frame = [UInt8](repeating: 0, count: 65)
        frame[0] = 0xAA
        frame[1] = 0x01
        frame[8] = 40
        frame[57] = 0x34
        frame[58] = 0x12
        frame[59] = 88
        frame[61] = 0xA4
        frame[62] = 0x01
        frame[63] = 2
        frame[64] = 0x10

        let candidate = try Whoop5RRDecoder.decodeRealtimeStepCounterCandidate(frame)
        XCTAssertEqual(candidate.selectedCounterCandidate, 0x1234)
        XCTAssertEqual(candidate.hardwareCounterCandidate, 420)
        XCTAssertEqual(candidate.cadenceRawCandidate, 88)
        XCTAssertEqual(candidate.activityRawCandidate, 2)
        XCTAssertTrue(candidate.softwareOverrideCandidate)
    }

    func testRealtimeHRRejectsWrongCandidateByteRange() {
        var frame = bytes("AA011800010022E12802ECFFE36A8F4257016F04000000000000010023BAA03D")
        frame[16] = 0xF3
        XCTAssertThrowsError(try Whoop5RRDecoder.decodeRealtimeHeartRate(frame))
    }

    func testExtractsCandidateHistoricalV18RRWordsWithoutUnitClaim() throws {
        // NOOP-sourced type-47 fixture only; offsets and units are not WHOOP-verified.
        let frame = bytes("aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817")
        XCTAssertEqual(try Whoop5RRDecoder.decodeHistoricalV18CandidateRRWords(frame), [602, 613])
    }

    func testUserHistoricalV18CaptureRetainsRRAndMotionFieldsAsCandidatesOnly() throws {
        let frame = bytes("AA01740001003FB12F128037170700FA9AE36A9939004B015F030000000000000000992C074B0000FF4034793C00005CBF71FD30BEC3B5FF3E6C01F200000000000000000031013B01F90C900A010C060C10000000000000000000000000000000000000000000000100A1B724230000001A30A8C00000002AC67557")
        XCTAssertEqual(try Whoop5RRDecoder.decodeHistoricalV18CandidateRRWords(frame), [863])
        let step = try Whoop5RRDecoder.decodeHistoricalV18StepCounterCandidate(frame)
        XCTAssertEqual(step.stepMotionCounterCandidate, 364)
        XCTAssertEqual(step.hardwareCounterCandidate, 0)
        XCTAssertFalse(step.softwareOverrideCandidate)
        XCTAssertEqual(step.stepCadenceRawCandidate, 242)
        XCTAssertEqual(step.activityClassRawCandidate, 0)
    }
    func testOpenStrapV18MotionFieldMappingRemainsCandidateOnly() throws {
        let frame = bytes("aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817")
        let step = try Whoop5RRDecoder.decodeHistoricalV18StepCounterCandidate(frame)
        XCTAssertEqual(step.stepMotionCounterCandidate, 50)
        XCTAssertEqual(step.hardwareCounterCandidate, 0)
        XCTAssertFalse(step.softwareOverrideCandidate)
        XCTAssertEqual(step.stepCadenceRawCandidate, 170)
        XCTAssertEqual(step.activityClassRawCandidate, 0)
    }
    func testRejectsUnknownStepCounterOverrideFlag() {
        var frame = bytes("aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817")
        frame[64] = 0x20
        XCTAssertThrowsError(try Whoop5RRDecoder.decodeHistoricalV18StepCounterCandidate(frame))
    }
    func testSoftwareOverrideFieldsRemainSeparateCandidates() throws {
        var frame = bytes("aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817")
        frame[57] = 0x84
        frame[58] = 0x03
        frame[61] = 0xA4
        frame[62] = 0x01
        frame[64] = 0x10
        let step = try Whoop5RRDecoder.decodeHistoricalV18StepCounterCandidate(frame)
        XCTAssertEqual(step.stepMotionCounterCandidate, 900)
        XCTAssertEqual(step.hardwareCounterCandidate, 420)
        XCTAssertTrue(step.softwareOverrideCandidate)
    }
    func testV18MotionFieldCandidatesRetainRawValuesWithoutStepConversion() throws {
        var frame = bytes("aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817")
        frame[57] = 0x34
        frame[58] = 0x12
        frame[59] = 88
        frame[63] = 2
        let decoded = try Whoop5RRDecoder.decodeHistoricalV18StepCounterCandidate(frame)
        XCTAssertEqual(decoded.stepMotionCounterCandidate, 0x1234)
        XCTAssertEqual(decoded.stepCadenceRawCandidate, 88)
        XCTAssertEqual(decoded.activityClassRawCandidate, 2)
    }
    func testMotionFieldCandidatesRemainIndependentOfRRWordPlausibility() throws {
        var frame = bytes("aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817")
        frame[24] = 1
        frame[25] = 0
        XCTAssertEqual(try Whoop5RRDecoder.decodeHistoricalV18CandidateRRWords(frame).first, 1)
        let step = try Whoop5RRDecoder.decodeHistoricalV18StepCounterCandidate(frame)
        XCTAssertEqual(step.stepMotionCounterCandidate, 50)
    }
    func testRealtimeCandidateWithZeroCountReturnsEmptyWordList() throws {
        // A zero candidate count yields no words; never synthesize RR values.
        var frame = bytes("aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc")
        frame[17] = 0
        XCTAssertEqual(try Whoop5RRDecoder.decodeRealtimeCandidateRRWords(frame), [])
    }

    func testRealtimeCandidateRejectsCountAboveDefensiveBound() {
        var frame = bytes("aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc")
        frame[17] = 33
        XCTAssertThrowsError(try Whoop5RRDecoder.decodeRealtimeCandidateRRWords(frame)) { error in
            XCTAssertEqual(error as? Whoop5RRDecoder.DecodeError, .invalidIntervalCount(33))
        }
    }

    func testHistoricalDecoderRejectsUnknownLayoutVersion() {
        var frame = bytes("aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817")
        frame[9] = 17
        XCTAssertThrowsError(try Whoop5RRDecoder.decodeHistoricalV18CandidateRRWords(frame)) { error in
            XCTAssertEqual(error as? Whoop5RRDecoder.DecodeError, .unsupportedHistoricalVersion(17))
        }
    }

    func testRealtimeDecoderRejectsInvalidFrameHeader() {
        var frame = bytes("aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc")
        frame[0] = 0xAB
        XCTAssertThrowsError(try Whoop5RRDecoder.decodeRealtimeCandidateRRWords(frame)) { error in
            XCTAssertEqual(error as? Whoop5RRDecoder.DecodeError, .invalidFrame)
        }
    }

    func testRealtimeDecoderDoesNotReadTrailingCRCAsRRData() {
        var frame = bytes("aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc")
        frame[17] = 7 // Claims seven RR words, but only two precede the CRC.
        XCTAssertThrowsError(try Whoop5RRDecoder.decodeRealtimeCandidateRRWords(frame)) { error in
            XCTAssertEqual(error as? Whoop5RRDecoder.DecodeError,
                           .truncatedIntervals(expectedBytes: 14, availableBytes: 10))
        }
    }

    func testRejectsWrongRecordType() {
        let frame = bytes("aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc")
        XCTAssertThrowsError(try Whoop5RRDecoder.decodeHistoricalV18CandidateRRWords(frame))
    }

    func testRejectsTruncatedIntervalWords() {
        let frame = bytes("aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc")
        XCTAssertThrowsError(try Whoop5RRDecoder.decodeRealtimeCandidateRRWords(Array(frame.prefix(23))))
    }

    func testCandidateWordExtractionPreservesZeroAndLargeValuesWithoutUnitAssumptions() throws {
        var frame = bytes("aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc")
        frame[18] = 0
        frame[19] = 0
        frame[20] = 0x88
        frame[21] = 0x13 // raw UInt16 value 5000; no millisecond claim
        XCTAssertEqual(try Whoop5RRDecoder.decodeRealtimeCandidateRRWords(frame), [0, 5000])
    }
}


final class WhoopRealtimeFreshnessTests: XCTestCase {
    func testNoPacketIsNotFresh() {
        XCTAssertFalse(WhoopRealtimeFreshness.isFresh(lastPacketAt: nil, now: Date()))
    }

    func testPacketIsFreshAtThirtySecondBoundary() {
        let now = Date(timeIntervalSince1970: 1_000)
        let packetAt = now.addingTimeInterval(-30)
        XCTAssertTrue(WhoopRealtimeFreshness.isFresh(lastPacketAt: packetAt, now: now))
    }

    func testPacketOlderThanThirtySecondsAllowsFallback() {
        let now = Date(timeIntervalSince1970: 1_000)
        let packetAt = now.addingTimeInterval(-30.001)
        XCTAssertFalse(WhoopRealtimeFreshness.isFresh(lastPacketAt: packetAt, now: now))
    }

    func testFutureDatedPacketDoesNotBlockFallback() {
        let now = Date(timeIntervalSince1970: 1_000)
        let packetAt = now.addingTimeInterval(1)
        XCTAssertFalse(WhoopRealtimeFreshness.isFresh(lastPacketAt: packetAt, now: now))
    }
}


final class RealtimeRMSSDCalculatorTests: XCTestCase {
    func testCalculatesRMSSDFromContiguousRRIntervals() {
        let result = RealtimeRMSSDCalculator.calculate(
            intervalsMilliseconds: [1000, 1010, 990, 1005, 995]
        )
        XCTAssertEqual(result ?? -1, (825.0 / 4.0).squareRoot(), accuracy: 0.0001)
    }

    func testRequiresAtLeastFiveIntervalsByDefault() {
        XCTAssertNil(RealtimeRMSSDCalculator.calculate(
            intervalsMilliseconds: [800, 805, 795, 802]
        ))
    }

    func testRejectsPhysiologicallyImplausibleIntervals() {
        XCTAssertNil(RealtimeRMSSDCalculator.calculate(
            intervalsMilliseconds: [800, 805, 0, 802, 799]
        ))
    }

    func testRejectsLargeAdjacentRRJump() {
        XCTAssertNil(RealtimeRMSSDCalculator.calculate(
            intervalsMilliseconds: [800, 805, 1200, 802, 799]
        ))
    }

    func testAcceptsStableSlowHeartRateIntervals() {
        XCTAssertNotNil(RealtimeRMSSDCalculator.calculate(
            intervalsMilliseconds: [1400, 1410, 1395, 1405, 1400]
        ))
    }
}


final class HistoricalAckWriteStateTests: XCTestCase {
    func testSuccessfulCoreBluetoothWriteStillAwaitsBandProgress() {
        XCTAssertEqual(
            HistoricalAckWriteState.resolve(errorDescription: nil),
            .acknowledgedAwaitingBandProgress
        )
    }

    func testFailedCoreBluetoothWriteIsNotReportedAsAcknowledged() {
        XCTAssertEqual(
            HistoricalAckWriteState.resolve(errorDescription: "The operation timed out."),
            .failed("The operation timed out.")
        )
    }

    func testEmptyErrorDescriptionDoesNotCreateFalseFailure() {
        XCTAssertEqual(
            HistoricalAckWriteState.resolve(errorDescription: ""),
            .acknowledgedAwaitingBandProgress
        )
    }
}
