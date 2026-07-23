import XCTest
@testable import MicroTechCGMKit

final class PublicationGateTests: XCTestCase {
    func testPublishesFirstThenAtFiveMinuteIntervals() {
        var gate = MicroTechPublicationGate()

        XCTAssertTrue(gate.shouldPublish(minuteIndex: 101))
        XCTAssertFalse(gate.shouldPublish(minuteIndex: 102))
        XCTAssertFalse(gate.shouldPublish(minuteIndex: 105))
        XCTAssertTrue(gate.shouldPublish(minuteIndex: 106))
        XCTAssertFalse(gate.shouldPublish(minuteIndex: 110))
        XCTAssertTrue(gate.shouldPublish(minuteIndex: 111))
    }

    func testRejectsDuplicateAndOutOfOrderIndexes() {
        var gate = MicroTechPublicationGate(lastPublishedMinute: 100)

        XCTAssertFalse(gate.shouldPublish(minuteIndex: 100))
        XCTAssertFalse(gate.shouldPublish(minuteIndex: 99))
        XCTAssertEqual(gate.lastPublishedMinute, 100)
    }

    func testRestoresLastPublishedMinute() {
        var gate = MicroTechPublicationGate(lastPublishedMinute: 200)

        XCTAssertFalse(gate.shouldPublish(minuteIndex: 204))
        XCTAssertTrue(gate.shouldPublish(minuteIndex: 205))
        XCTAssertEqual(gate.lastPublishedMinute, 205)
    }
}
