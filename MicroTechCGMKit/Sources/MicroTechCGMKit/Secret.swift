import Foundation

public struct MicroTechSecret: Equatable, Sendable {
    let bytes: [UInt8]

    /// A copy of the key bytes for storage in a platform credential store.
    public var keyBytes: [UInt8] {
        bytes
    }

    public init(keyBytes: [UInt8]) throws {
        guard keyBytes.count == MicroTechProtocolCrypto.keyLength else {
            throw MicroTechProtocolError.invalidKeyLength(
                expected: MicroTechProtocolCrypto.keyLength,
                actual: keyBytes.count
            )
        }
        bytes = keyBytes
    }
}

extension MicroTechSecret: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "<redacted \(bytes.count)-byte secret>"
    }

    public var debugDescription: String {
        description
    }
}
