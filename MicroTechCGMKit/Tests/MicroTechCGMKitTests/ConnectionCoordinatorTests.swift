import Foundation
import XCTest
@testable import MicroTechCGMKit

final class ConnectionCoordinatorTests: XCTestCase {
    private let deviceIdentifier = UUID(uuidString: "28EB6FC0-E6B8-42F6-8785-AE703510AE10")!
    private let masterKeyBytes = [UInt8](hexadecimalString: "2b7e151628aed2a6abf7158809cf4f3c")
    private let sessionKeyBytes = Array(UInt8(0x00) ... UInt8(0x0F))

    func testTransportFailureStopsTheCoordinatorSafely() throws {
        let serial = try MicroTechSensorSerial("A1B2C3D4E5")
        var coordinator = MicroTechConnectionCoordinator(serial: serial)

        _ = coordinator.handle(.start)
        let effects = coordinator.handle(
            .transportFailed(.characteristicDiscoveryFailed)
        )

        XCTAssertEqual(
            coordinator.state,
            .failed(.transportFailure(.characteristicDiscoveryFailed))
        )
        XCTAssertEqual(effects, [.transport(.disconnect)])
    }

    func testStaleTransportEventsAreIgnoredWhileIdle() throws {
        let serial = try MicroTechSensorSerial("A1B2C3D4E5")
        var coordinator = MicroTechConnectionCoordinator(serial: serial)

        XCTAssertTrue(coordinator.handle(.bluetoothUnavailable).isEmpty)
        XCTAssertTrue(
            coordinator.handle(.transportFailed(.deviceUnavailable)).isEmpty
        )
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testNewPairingSequenceAndEncryptedSynchronizationCommands() throws {
        let serial = try MicroTechSensorSerial("A1B2C3D4E5")
        let crypto = MicroTechProtocolCrypto(serial: serial)
        var coordinator = MicroTechConnectionCoordinator(serial: serial)

        XCTAssertEqual(
            coordinator.handle(.start),
            [.transport(.scan(serviceUUID: MicroTechBluetoothIdentifiers.service))]
        )
        XCTAssertEqual(coordinator.state, .scanning)

        XCTAssertEqual(
            coordinator.handle(.discovered(try device(serial: serial))),
            [
                .transport(.stopScanning),
                .transport(.connect(identifier: deviceIdentifier))
            ]
        )
        XCTAssertEqual(coordinator.state, .connecting)

        XCTAssertEqual(
            coordinator.handle(.connected),
            [.transport(.discoverCharacteristics(serviceUUID: MicroTechBluetoothIdentifiers.service))]
        )

        XCTAssertEqual(
            coordinator.handle(.characteristicsDiscovered(allCharacteristics)),
            [.transport(.enableNotifications(.keyExchange))]
        )
        XCTAssertEqual(coordinator.state, .subscribingKeyExchange)

        XCTAssertEqual(
            coordinator.handle(.notificationsEnabled(.keyExchange)),
            [.transport(.enableNotifications(.command))]
        )

        XCTAssertEqual(
            coordinator.handle(.notificationsEnabled(.command)),
            [
                .transport(
                    .write(
                        bytes: crypto.keyRequest,
                        characteristic: .keyExchange,
                        withResponse: true
                    )
                )
            ]
        )
        XCTAssertEqual(coordinator.state, .requestingMasterKey)

        let masterKey = try MicroTechSecret(keyBytes: masterKeyBytes)
        XCTAssertEqual(
            coordinator.handle(
                .valueReceived(characteristic: .keyExchange, bytes: masterKeyBytes)
            ),
            [
                .persistMasterKey(masterKey),
                .transport(.read(.command))
            ]
        )
        XCTAssertTrue(coordinator.hasMasterKey)
        XCTAssertEqual(coordinator.state, .requestingSessionKey)

        let sessionPacket = try encryptedSessionPacket(crypto: crypto)
        XCTAssertEqual(
            coordinator.handle(
                .valueReceived(characteristic: .command, bytes: sessionPacket)
            ),
            [.transport(.enableNotifications(.liveGlucose))]
        )
        XCTAssertEqual(coordinator.state, .subscribingLiveAfterAuthentication)

        let syncEffects = coordinator.handle(.notificationsEnabled(.liveGlucose))
        XCTAssertEqual(coordinator.state, .synchronizing)
        XCTAssertEqual(
            try decryptedCommandFrames(syncEffects, crypto: crypto),
            [
                MicroTechCommand.startTime.plaintextFrame,
                MicroTechCommand.historyRange.plaintextFrame
            ]
        )
    }

    func testReconnectSkipsKeyExchangeAndReusesMasterKey() throws {
        let serial = try MicroTechSensorSerial("A1B2C3D4E5")
        let masterKey = try MicroTechSecret(keyBytes: masterKeyBytes)
        let crypto = MicroTechProtocolCrypto(serial: serial)
        var coordinator = MicroTechConnectionCoordinator(serial: serial, masterKey: masterKey)

        _ = coordinator.handle(.start)
        _ = coordinator.handle(.discovered(try device(serial: serial)))
        _ = coordinator.handle(.connected)

        XCTAssertEqual(
            coordinator.handle(.characteristicsDiscovered(allCharacteristics)),
            [.transport(.enableNotifications(.liveGlucose))]
        )
        XCTAssertEqual(coordinator.state, .subscribingLiveBeforeCommand)

        XCTAssertEqual(
            coordinator.handle(.notificationsEnabled(.liveGlucose)),
            [.transport(.enableNotifications(.command))]
        )
        XCTAssertEqual(
            coordinator.handle(.notificationsEnabled(.command)),
            [.transport(.read(.command))]
        )

        let effects = coordinator.handle(
            .valueReceived(
                characteristic: .command,
                bytes: try encryptedSessionPacket(crypto: crypto)
            )
        )

        XCTAssertEqual(coordinator.state, .synchronizing)
        XCTAssertEqual(
            try decryptedCommandFrames(effects, crypto: crypto),
            [
                MicroTechCommand.startTime.plaintextFrame,
                MicroTechCommand.historyRange.plaintextFrame
            ]
        )
    }

    func testLiveOnlyModeEntersStreamingImmediatelyAfterAuthentication() throws {
        let serial = try MicroTechSensorSerial("A1B2C3D4E5")
        let masterKey = try MicroTechSecret(keyBytes: masterKeyBytes)
        let crypto = MicroTechProtocolCrypto(serial: serial)
        var coordinator = MicroTechConnectionCoordinator(
            serial: serial,
            masterKey: masterKey,
            synchronizationMode: .liveOnly
        )

        try advanceReconnectToSessionKey(&coordinator, serial: serial)
        let effects = coordinator.handle(
            .valueReceived(
                characteristic: .command,
                bytes: try encryptedSessionPacket(crypto: crypto)
            )
        )

        XCTAssertEqual(coordinator.state, .streaming)
        XCTAssertEqual(
            try decryptedCommandFrames(effects, crypto: crypto),
            [MicroTechCommand.currentGlucose.plaintextFrame]
        )
    }

    func testMissingRequiredCharacteristicFailsSafely() throws {
        let serial = try MicroTechSensorSerial("A1B2C3D4E5")
        var coordinator = MicroTechConnectionCoordinator(serial: serial)
        _ = coordinator.handle(.start)
        _ = coordinator.handle(.discovered(try device(serial: serial)))
        _ = coordinator.handle(.connected)

        let effects = coordinator.handle(
            .characteristicsDiscovered([.keyExchange, .command])
        )

        XCTAssertEqual(
            coordinator.state,
            .failed(.missingCharacteristics([.liveGlucose]))
        )
        XCTAssertEqual(effects, [.transport(.disconnect)])
    }

    func testInvalidSessionChecksumFailsSafely() throws {
        let serial = try MicroTechSensorSerial("A1B2C3D4E5")
        let masterKey = try MicroTechSecret(keyBytes: masterKeyBytes)
        let crypto = MicroTechProtocolCrypto(serial: serial)
        var coordinator = MicroTechConnectionCoordinator(serial: serial, masterKey: masterKey)
        try advanceReconnectToSessionKey(&coordinator, serial: serial)

        var invalidPlaintext = sessionKeyBytes
        invalidPlaintext.append(0x00)
        let invalidCiphertext = try crypto.encrypt(invalidPlaintext, with: masterKeyBytes)
        let effects = coordinator.handle(
            .valueReceived(characteristic: .command, bytes: invalidCiphertext)
        )

        XCTAssertEqual(coordinator.state, .failed(.protocolError(.checksumMismatch)))
        XCTAssertEqual(effects, [.transport(.disconnect)])
    }

    func testPagedBackfillDeduplicatesAndPublishesAtFiveMinuteCadence() throws {
        let serial = try MicroTechSensorSerial("A1B2C3D4E5")
        let crypto = MicroTechProtocolCrypto(serial: serial)
        var coordinator = try synchronizedCoordinator(
            serial: serial,
            lastReceivedMinute: 100,
            lastPublishedMinute: 100
        )

        let rangeEffects = coordinator.handle(.historyRange(latestMinute: 112))
        XCTAssertEqual(coordinator.state, .backfilling(nextMinute: 101, latestMinute: 112))
        XCTAssertEqual(
            try decryptedCommandFrames(rangeEffects, crypto: crypto),
            [MicroTechCommand.processedHistory(startingAt: 101).plaintextFrame]
        )

        let firstPageEffects = coordinator.handle(
            .historyPage(
                startingAt: 101,
                minuteIndexes: [103, 101, 102, 105, 106, 105, 104],
                hasMore: true
            )
        )
        XCTAssertEqual(coordinator.lastReceivedMinute, 106)
        XCTAssertEqual(coordinator.lastPublishedMinute, 105)
        XCTAssertTrue(firstPageEffects.contains(.publishHistoryMinuteIndexes([105])))
        XCTAssertEqual(
            try decryptedCommandFrames(firstPageEffects, crypto: crypto),
            [MicroTechCommand.processedHistory(startingAt: 107).plaintextFrame]
        )

        let secondPageEffects = coordinator.handle(
            .historyPage(
                startingAt: 107,
                minuteIndexes: [107, 108, 109, 110, 111, 112],
                hasMore: false
            )
        )
        XCTAssertEqual(coordinator.state, .streaming)
        XCTAssertEqual(coordinator.lastReceivedMinute, 112)
        XCTAssertEqual(coordinator.lastPublishedMinute, 110)
        XCTAssertTrue(secondPageEffects.contains(.publishHistoryMinuteIndexes([110])))
        XCTAssertEqual(
            try decryptedCommandFrames(secondPageEffects, crypto: crypto),
            [MicroTechCommand.currentGlucose.plaintextFrame]
        )
    }

    func testLivePacketsRespectSafetyAndPublicationGate() throws {
        let serial = try MicroTechSensorSerial("A1B2C3D4E5")
        var coordinator = try streamingCoordinator(
            serial: serial,
            lastReceivedMinute: 110,
            lastPublishedMinute: 110
        )

        XCTAssertTrue(
            coordinator.handle(
                .valueReceived(
                    characteristic: .liveGlucose,
                    bytes: try encryptedLiveFrame(serial: serial, minute: 113, warmup: true)
                )
            ).isEmpty
        )
        XCTAssertEqual(coordinator.lastReceivedMinute, 113)

        XCTAssertTrue(
            coordinator.handle(
                .valueReceived(
                    characteristic: .liveGlucose,
                    bytes: try encryptedLiveFrame(serial: serial, minute: 114, valid: false)
                )
            ).isEmpty
        )
        XCTAssertEqual(coordinator.lastReceivedMinute, 114)

        let publishEffects = coordinator.handle(
            .valueReceived(
                characteristic: .liveGlucose,
                bytes: try encryptedLiveFrame(serial: serial, minute: 115)
            )
        )
        guard case let .publishLiveGlucose(packet) = publishEffects.first else {
            return XCTFail("Expected a publish effect")
        }
        XCTAssertEqual(packet.minuteIndex, 115)
        XCTAssertEqual(coordinator.lastPublishedMinute, 115)

        XCTAssertTrue(
            coordinator.handle(
                .valueReceived(
                    characteristic: .liveGlucose,
                    bytes: try encryptedLiveFrame(serial: serial, minute: 115)
                )
            ).isEmpty
        )

        var invalidPlaintext = livePlaintextFrame(minute: 120)
        invalidPlaintext[8] ^= 0x01
        let invalidCrc = try MicroTechProtocolCrypto(serial: serial).encrypt(
            invalidPlaintext,
            with: sessionKeyBytes
        )
        XCTAssertEqual(
            coordinator.handle(
                .valueReceived(characteristic: .liveGlucose, bytes: invalidCrc)
            ),
            [.discardedLivePacket(.checksumMismatch)]
        )
        XCTAssertEqual(coordinator.lastReceivedMinute, 115)
    }

    func testUnexpectedHistoryPageFailsSafely() throws {
        let serial = try MicroTechSensorSerial("A1B2C3D4E5")
        var coordinator = try synchronizedCoordinator(
            serial: serial,
            lastReceivedMinute: 100,
            lastPublishedMinute: 100
        )
        _ = coordinator.handle(.historyRange(latestMinute: 110))

        let effects = coordinator.handle(
            .historyPage(startingAt: 102, minuteIndexes: [102], hasMore: true)
        )

        XCTAssertEqual(
            coordinator.state,
            .failed(.unexpectedHistoryPage(expectedStart: 101, actualStart: 102))
        )
        XCTAssertEqual(effects, [.transport(.disconnect)])
    }

    func testEmptyHistoryPageWithMoreDataFailsSafely() throws {
        let serial = try MicroTechSensorSerial("A1B2C3D4E5")
        var coordinator = try synchronizedCoordinator(
            serial: serial,
            lastReceivedMinute: 100,
            lastPublishedMinute: 100
        )
        _ = coordinator.handle(.historyRange(latestMinute: 110))

        let effects = coordinator.handle(
            .historyPage(startingAt: 101, minuteIndexes: [], hasMore: true)
        )

        XCTAssertEqual(coordinator.state, .failed(.historyDidNotAdvance))
        XCTAssertEqual(effects, [.transport(.disconnect)])
    }

    func testTimeoutAndRetryBackoffAreDeterministic() throws {
        let serial = try MicroTechSensorSerial("A1B2C3D4E5")
        let policy = MicroTechRetryPolicy(
            initialDelay: 2,
            multiplier: 2,
            maximumDelay: 5,
            maximumAttempts: 3
        )
        var coordinator = MicroTechConnectionCoordinator(serial: serial, retryPolicy: policy)
        _ = coordinator.handle(.start)

        XCTAssertEqual(
            coordinator.handle(.timeout),
            [
                .transport(.disconnect),
                .scheduleRetry(attempt: 1, delay: 2)
            ]
        )
        XCTAssertEqual(coordinator.state, .waitingToRetry(attempt: 1, delay: 2))

        XCTAssertEqual(
            coordinator.handle(.retryTimerFired),
            [.transport(.scan(serviceUUID: MicroTechBluetoothIdentifiers.service))]
        )

        XCTAssertEqual(
            coordinator.handle(.disconnected),
            [.scheduleRetry(attempt: 2, delay: 4)]
        )
        _ = coordinator.handle(.retryTimerFired)
        XCTAssertEqual(
            coordinator.handle(.disconnected),
            [.scheduleRetry(attempt: 3, delay: 5)]
        )
        _ = coordinator.handle(.retryTimerFired)

        XCTAssertTrue(coordinator.handle(.disconnected).isEmpty)
        XCTAssertEqual(coordinator.state, .failed(.retryLimitReached(attempts: 3)))
    }

    private var allCharacteristics: Set<MicroTechCharacteristic> {
        Set(MicroTechCharacteristic.allCases)
    }

    private func device(serial: MicroTechSensorSerial) throws -> MicroTechDiscoveredDevice {
        try XCTUnwrap(
            MicroTechDiscoveredDevice(
                identifier: deviceIdentifier,
                localName: "Smart-\(serial.normalizedValue)",
                advertisedServiceUUIDs: [MicroTechBluetoothIdentifiers.service]
            )
        )
    }

    private func encryptedSessionPacket(crypto: MicroTechProtocolCrypto) throws -> [UInt8] {
        var plaintext = sessionKeyBytes
        plaintext.append(MicroTechChecksums.crc8Maxim(sessionKeyBytes))
        return try crypto.encrypt(plaintext, with: masterKeyBytes)
    }

    private func decryptedCommandFrames(
        _ effects: [MicroTechCoordinatorEffect],
        crypto: MicroTechProtocolCrypto
    ) throws -> [[UInt8]] {
        try effects.compactMap { effect in
            guard case let .transport(.write(bytes, characteristic, withResponse)) = effect,
                  characteristic == .command,
                  withResponse
            else {
                return nil
            }
            return try crypto.decrypt(bytes, with: sessionKeyBytes)
        }
    }

    private func advanceReconnectToSessionKey(
        _ coordinator: inout MicroTechConnectionCoordinator,
        serial: MicroTechSensorSerial
    ) throws {
        _ = coordinator.handle(.start)
        _ = coordinator.handle(.discovered(try device(serial: serial)))
        _ = coordinator.handle(.connected)
        _ = coordinator.handle(.characteristicsDiscovered(allCharacteristics))
        _ = coordinator.handle(.notificationsEnabled(.liveGlucose))
        _ = coordinator.handle(.notificationsEnabled(.command))
        XCTAssertEqual(coordinator.state, .requestingSessionKey)
    }

    private func synchronizedCoordinator(
        serial: MicroTechSensorSerial,
        lastReceivedMinute: UInt16?,
        lastPublishedMinute: UInt16?
    ) throws -> MicroTechConnectionCoordinator {
        let masterKey = try MicroTechSecret(keyBytes: masterKeyBytes)
        let crypto = MicroTechProtocolCrypto(serial: serial)
        var coordinator = MicroTechConnectionCoordinator(
            serial: serial,
            masterKey: masterKey,
            lastReceivedMinute: lastReceivedMinute,
            lastPublishedMinute: lastPublishedMinute
        )
        try advanceReconnectToSessionKey(&coordinator, serial: serial)
        _ = coordinator.handle(
            .valueReceived(
                characteristic: .command,
                bytes: try encryptedSessionPacket(crypto: crypto)
            )
        )
        XCTAssertEqual(coordinator.state, .synchronizing)
        return coordinator
    }

    private func streamingCoordinator(
        serial: MicroTechSensorSerial,
        lastReceivedMinute: UInt16?,
        lastPublishedMinute: UInt16?
    ) throws -> MicroTechConnectionCoordinator {
        var coordinator = try synchronizedCoordinator(
            serial: serial,
            lastReceivedMinute: lastReceivedMinute,
            lastPublishedMinute: lastPublishedMinute
        )
        _ = coordinator.handle(.historyRange(latestMinute: lastReceivedMinute ?? 0))
        XCTAssertEqual(coordinator.state, .streaming)
        return coordinator
    }

    private func encryptedLiveFrame(
        serial: MicroTechSensorSerial,
        minute: UInt16,
        glucose: UInt16 = 137,
        trend: Int8 = -7,
        warmup: Bool = false,
        valid: Bool = true,
        messageKind: UInt16 = 1
    ) throws -> [UInt8] {
        try MicroTechProtocolCrypto(serial: serial).encrypt(
            livePlaintextFrame(
                minute: minute,
                glucose: glucose,
                trend: trend,
                warmup: warmup,
                valid: valid,
                messageKind: messageKind
            ),
            with: sessionKeyBytes
        )
    }

    private func livePlaintextFrame(
        minute: UInt16,
        glucose: UInt16 = 137,
        trend: Int8 = -7,
        warmup: Bool = false,
        valid: Bool = true,
        messageKind: UInt16 = 1
    ) -> [UInt8] {
        var packed = glucose & 0x03FF
        if warmup {
            packed |= 0x0400
        }
        if valid {
            packed |= 0x8000
        }

        let payload: [UInt8] = [
            UInt8(truncatingIfNeeded: messageKind),
            UInt8(truncatingIfNeeded: messageKind >> 8),
            0x00,
            UInt8(bitPattern: trend),
            UInt8(truncatingIfNeeded: minute),
            UInt8(truncatingIfNeeded: minute >> 8),
            UInt8(truncatingIfNeeded: packed),
            UInt8(truncatingIfNeeded: packed >> 8),
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        ]
        return MicroTechChecksums.appendingCrc16(to: payload)
    }
}
