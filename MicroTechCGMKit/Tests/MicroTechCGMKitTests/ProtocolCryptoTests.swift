import XCTest
@testable import MicroTechCGMKit

final class ProtocolCryptoTests: XCTestCase {
    func testSerialDerivationVector() throws {
        let crypto = MicroTechProtocolCrypto(serial: try MicroTechSensorSerial("A1B2C3D4E5"))

        XCTAssertEqual(
            crypto.keyRequest,
            [UInt8](hexadecimalString: "edce7079ff93d4462711ea7d80737883")
        )
        XCTAssertEqual(
            crypto.messageIV,
            [UInt8](hexadecimalString: "57c8da4f81310fa614a30c2776968a18")
        )
    }

    func testNistAesCfb128FirstBlock() throws {
        let crypto = try cryptoWithNistIV()
        let key = [UInt8](hexadecimalString: "2b7e151628aed2a6abf7158809cf4f3c")
        let plaintext = [UInt8](hexadecimalString: "6bc1bee22e409f96e93d7e117393172a")

        XCTAssertEqual(
            try crypto.encrypt(plaintext, with: key),
            [UInt8](hexadecimalString: "3b3fd92eb72dad20333449f8e83cfb4a")
        )
    }

    func testDecryptsSyntheticSessionKeyPacket() throws {
        let crypto = try cryptoWithNistIV()
        let masterKey = [UInt8](hexadecimalString: "2b7e151628aed2a6abf7158809cf4f3c")
        let ciphertext = [UInt8](hexadecimalString: "50ff65cf9d6834b1d2003de297a2e26f5f")

        XCTAssertEqual(
            try crypto.decryptSessionKeyPacket(ciphertext, masterKey: masterKey),
            Array(UInt8(0x00) ... UInt8(0x0F))
        )
    }

    func testRejectsSessionKeyPacketWithInvalidChecksum() throws {
        let crypto = try cryptoWithNistIV()
        let masterKey = [UInt8](hexadecimalString: "2b7e151628aed2a6abf7158809cf4f3c")
        var plaintext = Array(UInt8(0x00) ... UInt8(0x0F))
        plaintext.append(0x00)
        let ciphertext = try crypto.encrypt(plaintext, with: masterKey)

        XCTAssertThrowsError(
            try crypto.decryptSessionKeyPacket(ciphertext, masterKey: masterKey)
        ) { error in
            XCTAssertEqual(error as? MicroTechProtocolError, .checksumMismatch)
        }
    }

    func testRejectsInvalidKeyLength() throws {
        let crypto = MicroTechProtocolCrypto(serial: try MicroTechSensorSerial("A1B2C3D4E5"))

        XCTAssertThrowsError(try crypto.encrypt([0x10], with: [0x00])) { error in
            XCTAssertEqual(
                error as? MicroTechProtocolError,
                .invalidKeyLength(expected: 16, actual: 1)
            )
        }
    }

    private func cryptoWithNistIV() throws -> MicroTechProtocolCrypto {
        MicroTechProtocolCrypto(
            serial: try MicroTechSensorSerial("A1B2C3D4E5"),
            keyRequest: [],
            messageIV: [UInt8](hexadecimalString: "000102030405060708090a0b0c0d0e0f")
        )
    }
}
