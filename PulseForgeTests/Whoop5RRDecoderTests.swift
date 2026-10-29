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

    func testDecodesCapturedRealtimeRRInMilliseconds() throws {
        // Captured WHOOP 5 type-40 fixture: HR 98, RR 603/587 ms.
        let frame = bytes("aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc")
        XCTAssertEqual(try Whoop5RRDecoder.decodeRealtime(frame), [603, 587])
    }

    func testDecodesCapturedHistoricalV18RRInMilliseconds() throws {
        // Captured WHOOP 5 v18 type-47 fixture: HR 102, RR 602/613 ms.
        let frame = bytes("aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817")
        XCTAssertEqual(try Whoop5RRDecoder.decodeHistoricalV18(frame), [602, 613])
    }

    func testRejectsWrongRecordType() {
        let frame = bytes("aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc")
        XCTAssertThrowsError(try Whoop5RRDecoder.decodeHistoricalV18(frame))
    }

    func testRejectsTruncatedIntervalWords() {
        let frame = bytes("aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc")
        XCTAssertThrowsError(try Whoop5RRDecoder.decodeRealtime(Array(frame.prefix(23))))
    }

    func testRejectsZeroAndImplausibleRRValues() {
        let valid = bytes("aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc")
        var zero = valid
        zero[18] = 0
        zero[19] = 0
        XCTAssertThrowsError(try Whoop5RRDecoder.decodeRealtime(zero)) { error in
            XCTAssertEqual(error as? Whoop5RRDecoder.DecodeError, .invalidIntervalValue(0))
        }

        var corrupt = valid
        corrupt[18] = 0x88
        corrupt[19] = 0x13 // 5000 ms
        XCTAssertThrowsError(try Whoop5RRDecoder.decodeRealtime(corrupt)) { error in
            XCTAssertEqual(error as? Whoop5RRDecoder.DecodeError, .invalidIntervalValue(5000))
        }
    }
}
