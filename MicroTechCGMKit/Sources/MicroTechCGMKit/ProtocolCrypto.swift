import CryptoSwift
import Foundation

public struct MicroTechProtocolCrypto: Sendable {
    public static let keyLength = 16
    public static let sessionKeyPacketLength = 17

    public let serial: MicroTechSensorSerial
    public let keyRequest: [UInt8]
    public let messageIV: [UInt8]

    public init(serial: MicroTechSensorSerial) {
        self.serial = serial
        keyRequest = serial.mappedValues
            .map { $0 &* 13 &+ 61 }
            .md5()
        messageIV = serial.mappedValues
            .map { $0 &* 17 &+ 0x13 }
            .md5()
    }

    init(serial: MicroTechSensorSerial, keyRequest: [UInt8], messageIV: [UInt8]) {
        self.serial = serial
        self.keyRequest = keyRequest
        self.messageIV = messageIV
    }

    public func encrypt(_ plaintext: [UInt8], with key: [UInt8]) throws -> [UInt8] {
        try validateKey(key)

        do {
            let aes = try AES(
                key: key,
                blockMode: CFB(iv: messageIV, segmentSize: .cfb128),
                padding: .noPadding
            )
            return try aes.encrypt(plaintext)
        } catch let error as MicroTechProtocolError {
            throw error
        } catch {
            throw MicroTechProtocolError.encryptionFailed
        }
    }

    public func decrypt(_ ciphertext: [UInt8], with key: [UInt8]) throws -> [UInt8] {
        try validateKey(key)

        do {
            let aes = try AES(
                key: key,
                blockMode: CFB(iv: messageIV, segmentSize: .cfb128),
                padding: .noPadding
            )
            return try aes.decrypt(ciphertext)
        } catch let error as MicroTechProtocolError {
            throw error
        } catch {
            throw MicroTechProtocolError.decryptionFailed
        }
    }

    public func decryptSessionKeyPacket(_ ciphertext: [UInt8], masterKey: [UInt8]) throws -> [UInt8] {
        guard ciphertext.count == Self.sessionKeyPacketLength else {
            throw MicroTechProtocolError.invalidPacketLength(
                expected: Self.sessionKeyPacketLength,
                actual: ciphertext.count
            )
        }

        let plaintext = try decrypt(ciphertext, with: masterKey)
        let sessionKey = Array(plaintext.prefix(Self.keyLength))
        guard MicroTechChecksums.crc8Maxim(sessionKey) == plaintext[Self.keyLength] else {
            throw MicroTechProtocolError.checksumMismatch
        }
        return sessionKey
    }

    private func validateKey(_ key: [UInt8]) throws {
        guard key.count == Self.keyLength else {
            throw MicroTechProtocolError.invalidKeyLength(expected: Self.keyLength, actual: key.count)
        }
    }
}
