import XCTest
@testable import MicroTechCGMKit

final class CommandTests: XCTestCase {
    func testNoPayloadCommands() {
        XCTAssertEqual(MicroTechCommand.deviceInformation.plaintextFrame, [0x10, 0xC1, 0xF3])
        XCTAssertEqual(MicroTechCommand.currentGlucose.plaintextFrame, [0x11, 0xE0, 0xE3])
        XCTAssertEqual(MicroTechCommand.startTime.plaintextFrame, [0x21, 0xB3, 0xD5])
        XCTAssertEqual(MicroTechCommand.historyRange.plaintextFrame, [0x22, 0xD0, 0xE5])
    }

    func testProcessedHistoryUsesLittleEndianIndex() {
        XCTAssertEqual(
            MicroTechCommand.processedHistory(startingAt: 0x1234).plaintextFrame,
            MicroTechChecksums.appendingCrc16(to: [0x23, 0x34, 0x12])
        )
    }

    func testReconnectControlCommands() {
        XCTAssertEqual(MicroTechCommand.reconnectControl35.plaintextFrame, [0x35, 0x01, 0x4E, 0xF7])
        XCTAssertEqual(MicroTechCommand.reconnectControl34.plaintextFrame, [0x34, 0x01, 0x7F, 0xC4])
    }
}
