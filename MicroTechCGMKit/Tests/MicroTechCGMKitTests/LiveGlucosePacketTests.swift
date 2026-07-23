import Foundation
import XCTest
@testable import MicroTechCGMKit

final class LiveGlucosePacketTests: XCTestCase {
    func testDecodesSyntheticValidPacket() throws {
        let packet = try MicroTechLiveGlucosePacket(
            data: Data([UInt8](hexadecimalString: "010000f9d204898000000000000000d8c3"))
        )

        XCTAssertEqual(packet.messageKind, 1)
        XCTAssertEqual(packet.rawTrend, -7)
        XCTAssertEqual(packet.trendMgDLPerMinute, -0.7, accuracy: 0.0001)
        XCTAssertEqual(packet.minuteIndex, 1234)
        XCTAssertEqual(packet.processedGlucose.glucoseMgDL, 137)
        XCTAssertFalse(packet.processedGlucose.isWarmup)
        XCTAssertEqual(packet.processedGlucose.unknownFlags, 0)
        XCTAssertTrue(packet.processedGlucose.isValid)
        XCTAssertFalse(packet.indicatesEndedSensor)
        XCTAssertTrue(packet.hasUsableGlucose)
    }

    func testDecodesPackedFlagsWithoutTreatingThemAsKnownStatus() {
        let word = MicroTechProcessedGlucoseWord(rawValue: 0xFC89)

        XCTAssertEqual(word.glucoseMgDL, 137)
        XCTAssertTrue(word.isWarmup)
        XCTAssertEqual(word.unknownFlags, 15)
        XCTAssertTrue(word.isValid)
    }

    func testRejectsInvalidCrc() {
        var bytes = [UInt8](hexadecimalString: "010000f9d204898000000000000000d8c3")
        bytes[8] ^= 0x01

        XCTAssertThrowsError(try MicroTechLiveGlucosePacket(data: Data(bytes))) { error in
            XCTAssertEqual(error as? MicroTechProtocolError, .checksumMismatch)
        }
    }

    func testWarmupPacketIsNotUsable() throws {
        let packet = try MicroTechLiveGlucosePacket(
            data: Data([UInt8](hexadecimalString: "0100000cd2042c850000000000000054c4"))
        )

        XCTAssertEqual(packet.processedGlucose.glucoseMgDL, 300)
        XCTAssertTrue(packet.processedGlucose.isWarmup)
        XCTAssertTrue(packet.processedGlucose.isValid)
        XCTAssertFalse(packet.hasUsableGlucose)
    }

    func testEndedPacketIsNotUsable() throws {
        let payload: [UInt8] = [
            0x03, 0x00, 0x00, 0x00, 0xD2, 0x04, 0x89, 0x80,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        ]
        let frame = MicroTechChecksums.appendingCrc16(to: payload)
        let packet = try MicroTechLiveGlucosePacket(data: Data(frame))

        XCTAssertTrue(packet.indicatesEndedSensor)
        XCTAssertFalse(packet.hasUsableGlucose)
    }

    func testInvalidReadingIsNotUsable() throws {
        let payload: [UInt8] = [
            0x01, 0x00, 0x00, 0x00, 0xD2, 0x04, 0x89, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        ]
        let frame = MicroTechChecksums.appendingCrc16(to: payload)
        let packet = try MicroTechLiveGlucosePacket(data: Data(frame))

        XCTAssertFalse(packet.processedGlucose.isValid)
        XCTAssertFalse(packet.hasUsableGlucose)
    }

    func testRejectsEveryTruncation() {
        let bytes = [UInt8](hexadecimalString: "010000f9d204898000000000000000d8c3")

        for length in 0 ..< bytes.count {
            XCTAssertThrowsError(
                try MicroTechLiveGlucosePacket(data: Data(bytes.prefix(length)))
            )
        }
    }
}
