import XCTest
@testable import MicroTechCGMKit

final class DiscoveryReportTests: XCTestCase {
    func testRedactsTenCharacterSerialSuffix() {
        XCTAssertEqual(
            MicroTechDiscoveryReport.redact(localName: "Smart-A1B2C3D4E5"),
            "Smart-<redacted-10-character-suffix>"
        )
    }

    func testRedactsUnknownNameAfterSeparator() {
        XCTAssertEqual(
            MicroTechDiscoveryReport.redact(localName: "Unknown-ABC"),
            "Unknown-<redacted>"
        )
    }

    func testDoesNotExposeUnstructuredLocalName() {
        XCTAssertEqual(
            MicroTechDiscoveryReport.redact(localName: "SensitiveName"),
            "<redacted-local-name>"
        )
        XCTAssertEqual(
            MicroTechDiscoveryReport.redact(localName: nil),
            "<unavailable>"
        )
    }

    func testMalformedKnownFamilyNameDoesNotExposeExtraContent() {
        let redacted = MicroTechDiscoveryReport.redact(
            localName: "Smart-extra-A1B2C3D4E5"
        )

        XCTAssertEqual(redacted, "Smart-<redacted-invalid-local-name>")
        XCTAssertFalse(redacted.contains("extra"))
        XCTAssertFalse(redacted.contains("A1B2C3D4E5"))
    }

    func testReportNormalizesAndSortsMetadata() {
        let report = MicroTechDiscoveryReport(
            localName: "Smart-A1B2C3D4E5",
            advertisedServiceUUIDs: ["181f", "180D", "181F"],
            discoveredServiceUUIDs: ["fef5", "181f"],
            characteristics: [
                MicroTechCharacteristicMetadata(
                    serviceUUID: "181f",
                    characteristicUUID: "f003",
                    properties: [.notify]
                ),
                MicroTechCharacteristicMetadata(
                    serviceUUID: "181f",
                    characteristicUUID: "f001",
                    properties: [.write, .notify]
                )
            ]
        )

        XCTAssertEqual(report.advertisedServiceUUIDs, ["180D", "181F"])
        XCTAssertEqual(report.discoveredServiceUUIDs, ["181F", "FEF5"])
        XCTAssertEqual(
            report.characteristics.map(\.characteristicUUID),
            ["F001", "F003"]
        )
    }

    func testFormattedReportContainsBoundaryWithoutSensitiveValues() {
        let report = MicroTechDiscoveryReport(
            localName: "Smart-A1B2C3D4E5",
            advertisedServiceUUIDs: ["181F"],
            discoveredServiceUUIDs: ["181F"],
            characteristics: [
                MicroTechCharacteristicMetadata(
                    serviceUUID: "181F",
                    characteristicUUID: "F002",
                    properties: [.writeWithoutResponse, .write]
                )
            ]
        )

        XCTAssertTrue(report.formattedText.contains("read-only GATT metadata"))
        XCTAssertTrue(report.formattedText.contains("Peripheral identifier: <redacted>"))
        XCTAssertTrue(report.formattedText.contains("write, write-without-response"))
        XCTAssertFalse(report.formattedText.contains("A1B2C3D4E5"))
    }

    func testEmptyMetadataIsRenderedExplicitly() {
        let report = MicroTechDiscoveryReport(
            localName: nil,
            advertisedServiceUUIDs: [],
            discoveredServiceUUIDs: [],
            characteristics: []
        )

        XCTAssertEqual(report.formattedText.components(separatedBy: "- <none>").count - 1, 3)
    }
}
