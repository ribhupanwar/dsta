import XCTest
@testable import PulseForge

final class Whoop5FrameValidatorTests: XCTestCase {
    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        }
    }

    private let userCapture = "AA01740001003FB12F128037170700FA9AE36A9939004B015F030000000000000000992C074B0000FF4034793C00005CBF71FD30BEC3B5FF3E6C01F200000000000000000031013B01F90C900A010C060C10000000000000000000000000000000000000000000000100A1B724230000001A30A8C00000002AC67557"

    func testAcceptsCRCValidWHOOPType47V18DeviceCapture() {
        XCTAssertTrue(Whoop5FrameValidator.isValid(bytes(userCapture)))
    }

    func testRejectsHeaderCRCMutation() {
        var frame = bytes(userCapture)
        frame[4] ^= 0x01
        XCTAssertFalse(Whoop5FrameValidator.isValid(frame))
    }

    func testRejectsPayloadMutationWithStaleCRC() {
        var frame = bytes(userCapture)
        frame[30] ^= 0x01
        XCTAssertFalse(Whoop5FrameValidator.isValid(frame))
    }

    func testRejectsTruncatedFrame() {
        var frame = bytes(userCapture)
        frame.removeLast()
        XCTAssertFalse(Whoop5FrameValidator.isValid(frame))
    }
}
