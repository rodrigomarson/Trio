import Foundation

public enum MicroTechTransportCommand: Equatable, Sendable {
    case scan(serviceUUID: String)
    case stopScanning
    case connect(identifier: UUID)
    case discoverCharacteristics(serviceUUID: String)
    case enableNotifications(MicroTechCharacteristic)
    case read(MicroTechCharacteristic)
    case write(bytes: [UInt8], characteristic: MicroTechCharacteristic, withResponse: Bool)
    case disconnect
}

public protocol MicroTechTransport: AnyObject {
    func perform(_ command: MicroTechTransportCommand)
}

public final class MicroTechSimulatedTransport: MicroTechTransport {
    public private(set) var performedCommands: [MicroTechTransportCommand] = []

    public init() {}

    public func perform(_ command: MicroTechTransportCommand) {
        performedCommands.append(command)
    }

    public func reset() {
        performedCommands.removeAll()
    }
}
