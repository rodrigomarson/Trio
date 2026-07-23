import Foundation

public struct MicroTechRetryPolicy: Equatable, Sendable {
    public let initialDelay: TimeInterval
    public let multiplier: Double
    public let maximumDelay: TimeInterval
    public let maximumAttempts: Int

    public init(
        initialDelay: TimeInterval = 2,
        multiplier: Double = 2,
        maximumDelay: TimeInterval = 30,
        maximumAttempts: Int = 5
    ) {
        precondition(initialDelay > 0)
        precondition(multiplier >= 1)
        precondition(maximumDelay >= initialDelay)
        precondition(maximumAttempts > 0)

        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maximumDelay = maximumDelay
        self.maximumAttempts = maximumAttempts
    }

    public func delay(forAttempt attempt: Int) -> TimeInterval {
        precondition(attempt > 0)

        var delay = initialDelay
        if attempt > 1 {
            for _ in 1 ..< attempt {
                delay *= multiplier
            }
        }
        return min(delay, maximumDelay)
    }
}

public enum MicroTechConnectionFailure: Equatable, Sendable {
    case bluetoothUnavailable
    case transportFailure(MicroTechTransportFailure)
    case missingCharacteristics(Set<MicroTechCharacteristic>)
    case protocolError(MicroTechProtocolError)
    case unexpectedHistoryPage(expectedStart: UInt16, actualStart: UInt16)
    case historyDidNotAdvance
    case retryLimitReached(attempts: Int)
}

public enum MicroTechConnectionState: Equatable, Sendable {
    case idle
    case scanning
    case connecting
    case discovering
    case subscribingKeyExchange
    case subscribingLiveBeforeCommand
    case subscribingCommand
    case requestingMasterKey
    case requestingSessionKey
    case subscribingLiveAfterAuthentication
    case synchronizing
    case backfilling(nextMinute: UInt16, latestMinute: UInt16)
    case streaming
    case waitingToRetry(attempt: Int, delay: TimeInterval)
    case failed(MicroTechConnectionFailure)
}

/// Selects how the coordinator transitions from authentication to live glucose.
///
/// History synchronization remains available for protocol development. Clients
/// that do not implement MicroTech history response decoding should use
/// `liveOnly` so authentication cannot stall before live notifications are
/// published.
public enum MicroTechSynchronizationMode: Equatable, Sendable {
    case history
    case liveOnly
}

public enum MicroTechCoordinatorEvent: Equatable, Sendable {
    case start
    case stop
    case bluetoothUnavailable
    case transportFailed(MicroTechTransportFailure)
    case discovered(MicroTechDiscoveredDevice)
    case connected
    case characteristicsDiscovered(Set<MicroTechCharacteristic>)
    case notificationsEnabled(MicroTechCharacteristic)
    case valueReceived(characteristic: MicroTechCharacteristic, bytes: [UInt8])
    case historyRange(latestMinute: UInt16)
    case historyPage(startingAt: UInt16, minuteIndexes: [UInt16], hasMore: Bool)
    case disconnected
    case timeout
    case retryTimerFired
}

public enum MicroTechCoordinatorEffect: Equatable, Sendable {
    case transport(MicroTechTransportCommand)
    case persistMasterKey(MicroTechSecret)
    case publishHistoryMinuteIndexes([UInt16])
    case publishLiveGlucose(MicroTechLiveGlucosePacket)
    case discardedLivePacket(MicroTechProtocolError)
    case scheduleRetry(attempt: Int, delay: TimeInterval)
}

public struct MicroTechConnectionCoordinator: Sendable {
    public let serial: MicroTechSensorSerial
    public private(set) var state: MicroTechConnectionState = .idle
    public private(set) var lastReceivedMinute: UInt16?

    public var lastPublishedMinute: UInt16? {
        publicationGate.lastPublishedMinute
    }

    public var hasMasterKey: Bool {
        masterKey != nil
    }

    private let crypto: MicroTechProtocolCrypto
    private let retryPolicy: MicroTechRetryPolicy
    private let synchronizationMode: MicroTechSynchronizationMode
    private var publicationGate: MicroTechPublicationGate
    private var masterKey: MicroTechSecret?
    private var sessionKey: MicroTechSecret?
    private var liveNotificationsEnabled = false
    private var retryAttempt = 0

    public init(
        serial: MicroTechSensorSerial,
        masterKey: MicroTechSecret? = nil,
        lastReceivedMinute: UInt16? = nil,
        lastPublishedMinute: UInt16? = nil,
        retryPolicy: MicroTechRetryPolicy = MicroTechRetryPolicy(),
        synchronizationMode: MicroTechSynchronizationMode = .history
    ) {
        self.serial = serial
        self.masterKey = masterKey
        self.lastReceivedMinute = lastReceivedMinute
        self.retryPolicy = retryPolicy
        self.synchronizationMode = synchronizationMode
        crypto = MicroTechProtocolCrypto(serial: serial)
        publicationGate = MicroTechPublicationGate(lastPublishedMinute: lastPublishedMinute)
    }

    @discardableResult
    public mutating func handle(
        _ event: MicroTechCoordinatorEvent,
        using transport: MicroTechTransport
    ) -> [MicroTechCoordinatorEffect] {
        let effects = handle(event)
        for effect in effects {
            if case let .transport(command) = effect {
                transport.perform(command)
            }
        }
        return effects
    }

    public mutating func handle(_ event: MicroTechCoordinatorEvent) -> [MicroTechCoordinatorEffect] {
        switch event {
        case .start:
            guard state == .idle else {
                return []
            }
            retryAttempt = 0
            state = .scanning
            return [.transport(.scan(serviceUUID: MicroTechBluetoothIdentifiers.service))]

        case .stop:
            guard state != .idle else {
                return []
            }
            resetTransientConnectionState()
            retryAttempt = 0
            state = .idle
            return [.transport(.disconnect)]

        case .bluetoothUnavailable:
            guard state != .idle else {
                return []
            }
            return fail(.bluetoothUnavailable, disconnect: false)

        case let .transportFailed(failure):
            guard state != .idle else {
                return []
            }
            return fail(.transportFailure(failure), disconnect: true)

        case let .discovered(device):
            guard state == .scanning, device.serial == serial else {
                return []
            }
            state = .connecting
            return [
                .transport(.stopScanning),
                .transport(.connect(identifier: device.identifier))
            ]

        case .connected:
            guard state == .connecting else {
                return []
            }
            state = .discovering
            return [
                .transport(.discoverCharacteristics(serviceUUID: MicroTechBluetoothIdentifiers.service))
            ]

        case let .characteristicsDiscovered(characteristics):
            guard state == .discovering else {
                return []
            }
            return handleDiscoveredCharacteristics(characteristics)

        case let .notificationsEnabled(characteristic):
            return handleNotificationsEnabled(characteristic)

        case let .valueReceived(characteristic, bytes):
            return handleValue(characteristic: characteristic, bytes: bytes)

        case let .historyRange(latestMinute):
            return handleHistoryRange(latestMinute)

        case let .historyPage(startingAt, minuteIndexes, hasMore):
            return handleHistoryPage(
                startingAt: startingAt,
                minuteIndexes: minuteIndexes,
                hasMore: hasMore
            )

        case .disconnected:
            guard state != .idle else {
                return []
            }
            if case .failed = state {
                resetTransientConnectionState()
                return []
            }
            resetTransientConnectionState()
            return scheduleRetry()

        case .timeout:
            guard state != .idle else {
                return []
            }
            if case .failed = state {
                return []
            }
            resetTransientConnectionState()
            return [.transport(.disconnect)] + scheduleRetry()

        case .retryTimerFired:
            guard case .waitingToRetry = state else {
                return []
            }
            state = .scanning
            return [.transport(.scan(serviceUUID: MicroTechBluetoothIdentifiers.service))]
        }
    }

    private mutating func handleDiscoveredCharacteristics(
        _ characteristics: Set<MicroTechCharacteristic>
    ) -> [MicroTechCoordinatorEffect] {
        var required: Set<MicroTechCharacteristic> = [.command, .liveGlucose]
        if masterKey == nil {
            required.insert(.keyExchange)
        }

        let missing = required.subtracting(characteristics)
        guard missing.isEmpty else {
            return fail(.missingCharacteristics(missing), disconnect: true)
        }

        if masterKey == nil {
            state = .subscribingKeyExchange
            return [.transport(.enableNotifications(.keyExchange))]
        } else {
            state = .subscribingLiveBeforeCommand
            return [.transport(.enableNotifications(.liveGlucose))]
        }
    }

    private mutating func handleNotificationsEnabled(
        _ characteristic: MicroTechCharacteristic
    ) -> [MicroTechCoordinatorEffect] {
        switch (state, characteristic) {
        case (.subscribingKeyExchange, .keyExchange):
            state = .subscribingCommand
            return [.transport(.enableNotifications(.command))]

        case (.subscribingLiveBeforeCommand, .liveGlucose):
            liveNotificationsEnabled = true
            state = .subscribingCommand
            return [.transport(.enableNotifications(.command))]

        case (.subscribingCommand, .command):
            if masterKey == nil {
                state = .requestingMasterKey
                return [
                    .transport(
                        .write(
                            bytes: crypto.keyRequest,
                            characteristic: .keyExchange,
                            withResponse: true
                        )
                    )
                ]
            } else {
                state = .requestingSessionKey
                return [.transport(.read(.command))]
            }

        case (.subscribingLiveAfterAuthentication, .liveGlucose):
            liveNotificationsEnabled = true
            return beginSynchronization()

        default:
            return []
        }
    }

    private mutating func handleValue(
        characteristic: MicroTechCharacteristic,
        bytes: [UInt8]
    ) -> [MicroTechCoordinatorEffect] {
        switch (state, characteristic) {
        case (.requestingMasterKey, .keyExchange):
            do {
                let secret = try MicroTechSecret(keyBytes: bytes)
                masterKey = secret
                state = .requestingSessionKey
                return [
                    .persistMasterKey(secret),
                    .transport(.read(.command))
                ]
            } catch let error as MicroTechProtocolError {
                return fail(.protocolError(error), disconnect: true)
            } catch {
                return fail(.protocolError(.decryptionFailed), disconnect: true)
            }

        case (.requestingSessionKey, .command):
            guard let masterKey else {
                return fail(
                    .protocolError(
                        .invalidKeyLength(expected: MicroTechProtocolCrypto.keyLength, actual: 0)
                    ),
                    disconnect: true
                )
            }

            do {
                let sessionKeyBytes = try crypto.decryptSessionKeyPacket(bytes, masterKey: masterKey.bytes)
                sessionKey = try MicroTechSecret(keyBytes: sessionKeyBytes)

                if liveNotificationsEnabled {
                    return beginSynchronization()
                } else {
                    state = .subscribingLiveAfterAuthentication
                    return [.transport(.enableNotifications(.liveGlucose))]
                }
            } catch let error as MicroTechProtocolError {
                return fail(.protocolError(error), disconnect: true)
            } catch {
                return fail(.protocolError(.decryptionFailed), disconnect: true)
            }

        case (.streaming, .liveGlucose):
            return handleLivePacket(bytes)

        default:
            return []
        }
    }

    private mutating func beginSynchronization() -> [MicroTechCoordinatorEffect] {
        if synchronizationMode == .liveOnly {
            return enterStreaming()
        }

        state = .synchronizing

        do {
            return [
                .transport(try writeCommand(.startTime)),
                .transport(try writeCommand(.historyRange))
            ]
        } catch let error as MicroTechProtocolError {
            return fail(.protocolError(error), disconnect: true)
        } catch {
            return fail(.protocolError(.encryptionFailed), disconnect: true)
        }
    }

    private mutating func handleHistoryRange(
        _ latestMinute: UInt16
    ) -> [MicroTechCoordinatorEffect] {
        guard state == .synchronizing else {
            return []
        }

        let startingMinute: UInt16
        if let lastReceivedMinute {
            guard lastReceivedMinute < latestMinute else {
                return enterStreaming()
            }
            startingMinute = lastReceivedMinute + 1
        } else {
            startingMinute = latestMinute
        }

        state = .backfilling(nextMinute: startingMinute, latestMinute: latestMinute)
        do {
            return [
                .transport(try writeCommand(.processedHistory(startingAt: startingMinute)))
            ]
        } catch let error as MicroTechProtocolError {
            return fail(.protocolError(error), disconnect: true)
        } catch {
            return fail(.protocolError(.encryptionFailed), disconnect: true)
        }
    }

    private mutating func handleHistoryPage(
        startingAt: UInt16,
        minuteIndexes: [UInt16],
        hasMore: Bool
    ) -> [MicroTechCoordinatorEffect] {
        guard case let .backfilling(expectedStart, latestMinute) = state else {
            return []
        }
        guard startingAt == expectedStart else {
            return fail(
                .unexpectedHistoryPage(expectedStart: expectedStart, actualStart: startingAt),
                disconnect: true
            )
        }

        let previouslyReceivedMinute = lastReceivedMinute
        let accepted = Array(Set(minuteIndexes))
            .filter { minute in
                minute >= expectedStart &&
                    minute <= latestMinute &&
                    (previouslyReceivedMinute.map { minute > $0 } ?? true)
            }
            .sorted()

        guard let lastAccepted = accepted.last else {
            if hasMore {
                return fail(.historyDidNotAdvance, disconnect: true)
            }
            return enterStreaming()
        }

        lastReceivedMinute = lastAccepted

        var selectedForPublication: [UInt16] = []
        for minute in accepted where publicationGate.shouldPublish(minuteIndex: minute) {
            selectedForPublication.append(minute)
        }

        var effects: [MicroTechCoordinatorEffect] = []
        if !selectedForPublication.isEmpty {
            effects.append(.publishHistoryMinuteIndexes(selectedForPublication))
        }

        if hasMore, lastAccepted < latestMinute {
            let nextMinute = lastAccepted + 1
            state = .backfilling(nextMinute: nextMinute, latestMinute: latestMinute)
            do {
                effects.append(
                    .transport(try writeCommand(.processedHistory(startingAt: nextMinute)))
                )
                return effects
            } catch let error as MicroTechProtocolError {
                return effects + fail(.protocolError(error), disconnect: true)
            } catch {
                return effects + fail(.protocolError(.encryptionFailed), disconnect: true)
            }
        }

        return effects + enterStreaming()
    }

    private mutating func handleLivePacket(_ bytes: [UInt8]) -> [MicroTechCoordinatorEffect] {
        do {
            guard let sessionKey else {
                throw MicroTechProtocolError.invalidKeyLength(
                    expected: MicroTechProtocolCrypto.keyLength,
                    actual: 0
                )
            }
            let plaintext = try crypto.decrypt(bytes, with: sessionKey.bytes)
            let packet = try MicroTechLiveGlucosePacket(data: Data(plaintext))

            if let lastReceivedMinute, packet.minuteIndex <= lastReceivedMinute {
                return []
            }
            lastReceivedMinute = packet.minuteIndex

            guard packet.hasUsableGlucose,
                  publicationGate.shouldPublish(minuteIndex: packet.minuteIndex)
            else {
                return []
            }

            return [.publishLiveGlucose(packet)]
        } catch let error as MicroTechProtocolError {
            return [.discardedLivePacket(error)]
        } catch {
            return [.discardedLivePacket(.decryptionFailed)]
        }
    }

    private mutating func enterStreaming() -> [MicroTechCoordinatorEffect] {
        state = .streaming
        retryAttempt = 0

        do {
            return [.transport(try writeCommand(.currentGlucose))]
        } catch let error as MicroTechProtocolError {
            return fail(.protocolError(error), disconnect: true)
        } catch {
            return fail(.protocolError(.encryptionFailed), disconnect: true)
        }
    }

    private func writeCommand(_ command: MicroTechCommand) throws -> MicroTechTransportCommand {
        guard let sessionKey else {
            throw MicroTechProtocolError.invalidKeyLength(
                expected: MicroTechProtocolCrypto.keyLength,
                actual: 0
            )
        }
        let encrypted = try crypto.encrypt(command.plaintextFrame, with: sessionKey.bytes)
        return .write(bytes: encrypted, characteristic: .command, withResponse: true)
    }

    private mutating func scheduleRetry() -> [MicroTechCoordinatorEffect] {
        retryAttempt += 1
        guard retryAttempt <= retryPolicy.maximumAttempts else {
            state = .failed(.retryLimitReached(attempts: retryPolicy.maximumAttempts))
            return []
        }

        let delay = retryPolicy.delay(forAttempt: retryAttempt)
        state = .waitingToRetry(attempt: retryAttempt, delay: delay)
        return [.scheduleRetry(attempt: retryAttempt, delay: delay)]
    }

    private mutating func fail(
        _ failure: MicroTechConnectionFailure,
        disconnect: Bool
    ) -> [MicroTechCoordinatorEffect] {
        sessionKey = nil
        liveNotificationsEnabled = false
        state = .failed(failure)
        return disconnect ? [.transport(.disconnect)] : []
    }

    private mutating func resetTransientConnectionState() {
        sessionKey = nil
        liveNotificationsEnabled = false
    }
}
