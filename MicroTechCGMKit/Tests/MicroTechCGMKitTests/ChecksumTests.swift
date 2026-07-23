import XCTest
@testable import MicroTechCGMKit

final class ChecksumTests: XCTestCase {
    func testCrc8MaximVector() {
        XCTAssertEqual(
            MicroTechChecksums.crc8Maxim(Array(UInt8(0x00) ... UInt8(0x0F))),
            0x3C
        )
    }

    func testCrc16CommandVectors() {
        let vectors: [([UInt8], UInt16)] = [
            ([0x10], 0xF3C1),
            ([0x11], 0xE3E0),
            ([0x21], 0xD5B3),
            ([0x22], 0xE5D0),
            ([0x23, 0x00, 0x00], 0x130A),
            ([0x35, 0x01], 0xF74E),
            ([0x34, 0x01], 0xC47F)
        ]

        for (input, expected) in vectors {
            XCTAssertEqual(MicroTechChecksums.crc16CcittFalse(input), expected)
        }
    }

    func testTrailingCrcWireOrder() {
        XCTAssertEqual(
            MicroTechChecksums.appendingCrc16(to: [0x10]),
            [0x10, 0xC1, 0xF3]
        )
    }
}
