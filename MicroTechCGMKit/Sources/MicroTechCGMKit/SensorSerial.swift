import Foundation

public struct MicroTechSensorSerial: Hashable, Codable, Sendable {
    public static let requiredLength = 10

    public let normalizedValue: String

    public init(_ value: String) throws {
        let characters = Array(value)
        guard characters.count == Self.requiredLength else {
            throw MicroTechProtocolError.invalidSerialLength(actual: characters.count)
        }

        var normalized = ""
        normalized.reserveCapacity(Self.requiredLength)

        for character in characters {
            guard character.isASCII, character.isLetter || character.isNumber else {
                throw MicroTechProtocolError.invalidSerialCharacter(character)
            }

            let uppercased = String(character).uppercased()
            guard uppercased.utf8.count == 1,
                  let byte = uppercased.utf8.first,
                  (byte >= CharacterByte.zero && byte <= CharacterByte.nine) ||
                  (byte >= CharacterByte.uppercaseA && byte <= CharacterByte.uppercaseZ)
            else {
                throw MicroTechProtocolError.invalidSerialCharacter(character)
            }
            normalized.append(Character(uppercased))
        }

        normalizedValue = normalized
    }

    var mappedValues: [UInt8] {
        normalizedValue.utf8.map { byte in
            if byte >= CharacterByte.zero, byte <= CharacterByte.nine {
                return byte - CharacterByte.zero
            }
            return byte - CharacterByte.uppercaseA + 10
        }
    }
}

private enum CharacterByte {
    static let zero = Character("0").asciiValue!
    static let nine = Character("9").asciiValue!
    static let uppercaseA = Character("A").asciiValue!
    static let uppercaseZ = Character("Z").asciiValue!
}
