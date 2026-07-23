import Foundation

public enum MicroTechCharacteristicProperty: String, CaseIterable, Hashable, Sendable {
    case broadcast
    case read
    case writeWithoutResponse = "write-without-response"
    case write
    case notify
    case indicate
    case authenticatedSignedWrites = "authenticated-signed-writes"
    case extendedProperties = "extended-properties"
    case notifyEncryptionRequired = "notify-encryption-required"
    case indicateEncryptionRequired = "indicate-encryption-required"
}

public struct MicroTechCharacteristicMetadata: Equatable, Sendable {
    public let serviceUUID: String
    public let characteristicUUID: String
    public let properties: Set<MicroTechCharacteristicProperty>

    public init(
        serviceUUID: String,
        characteristicUUID: String,
        properties: Set<MicroTechCharacteristicProperty>
    ) {
        self.serviceUUID = serviceUUID.uppercased()
        self.characteristicUUID = characteristicUUID.uppercased()
        self.properties = properties
    }
}

public struct MicroTechDiscoveryReport: Equatable, Sendable {
    public let redactedLocalName: String
    public let advertisedServiceUUIDs: [String]
    public let discoveredServiceUUIDs: [String]
    public let characteristics: [MicroTechCharacteristicMetadata]

    public init(
        localName: String?,
        advertisedServiceUUIDs: [String],
        discoveredServiceUUIDs: [String],
        characteristics: [MicroTechCharacteristicMetadata]
    ) {
        redactedLocalName = Self.redact(localName: localName)
        self.advertisedServiceUUIDs = Self.normalized(advertisedServiceUUIDs)
        self.discoveredServiceUUIDs = Self.normalized(discoveredServiceUUIDs)
        self.characteristics = characteristics.sorted {
            if $0.serviceUUID == $1.serviceUUID {
                return $0.characteristicUUID < $1.characteristicUUID
            }
            return $0.serviceUUID < $1.serviceUUID
        }
    }

    public var formattedText: String {
        var lines = [
            "MicroTech SMART 2.0 metadata discovery report",
            "Mode: read-only GATT metadata; no characteristic values read",
            "Local name: \(redactedLocalName)",
            "Peripheral identifier: <redacted>",
            "",
            "Advertised services:"
        ]

        lines.append(contentsOf: Self.listLines(advertisedServiceUUIDs))
        lines.append("")
        lines.append("Discovered services:")
        lines.append(contentsOf: Self.listLines(discoveredServiceUUIDs))
        lines.append("")
        lines.append("Characteristics:")

        if characteristics.isEmpty {
            lines.append("- <none>")
        } else {
            for characteristic in characteristics {
                let properties = characteristic.properties
                    .map(\.rawValue)
                    .sorted()
                    .joined(separator: ", ")
                let renderedProperties = properties.isEmpty ? "<none>" : properties
                lines.append(
                    "- service \(characteristic.serviceUUID); " +
                        "characteristic \(characteristic.characteristicUUID); " +
                        "properties: \(renderedProperties)"
                )
            }
        }

        lines.append("")
        lines.append(
            "Safety: no characteristic-value reads, notifications, pairing commands, " +
                "or writes were requested."
        )
        return lines.joined(separator: "\n") + "\n"
    }

    public static func redact(localName: String?) -> String {
        guard let localName, !localName.isEmpty else {
            return "<unavailable>"
        }

        let suffixLength = MicroTechSensorSerial.requiredLength
        if let family = MicroTechDeviceFamily.allCases.first(where: {
            localName.hasPrefix($0.localNamePrefix)
        }) {
            let expectedLength = family.localNamePrefix.count + suffixLength
            let suffix = localName.suffix(suffixLength)
            let suffixIsValid = suffix.unicodeScalars
                .allSatisfy(Self.isASCIIAlphanumeric)
            if localName.count == expectedLength, suffixIsValid {
                return family.localNamePrefix +
                    "<redacted-10-character-suffix>"
            }
            return family.localNamePrefix + "<redacted-invalid-local-name>"
        }

        if let separator = localName.lastIndex(of: "-"),
           separator < localName.index(before: localName.endIndex)
        {
            return String(localName[...separator]) + "<redacted>"
        }

        return "<redacted-local-name>"
    }

    private static func normalized(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.uppercased() })).sorted()
    }

    private static func listLines(_ values: [String]) -> [String] {
        values.isEmpty ? ["- <none>"] : values.map { "- \($0)" }
    }

    private static func isASCIIAlphanumeric(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48 ... 57, 65 ... 90, 97 ... 122:
            return true
        default:
            return false
        }
    }
}
