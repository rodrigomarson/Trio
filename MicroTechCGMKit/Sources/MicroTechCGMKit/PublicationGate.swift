import Foundation

public struct MicroTechPublicationGate: Equatable, Sendable {
    public let minimumIntervalMinutes: UInt16
    public private(set) var lastPublishedMinute: UInt16?

    public init(minimumIntervalMinutes: UInt16 = 5, lastPublishedMinute: UInt16? = nil) {
        precondition(minimumIntervalMinutes > 0)
        self.minimumIntervalMinutes = minimumIntervalMinutes
        self.lastPublishedMinute = lastPublishedMinute
    }

    public mutating func shouldPublish(minuteIndex: UInt16) -> Bool {
        guard let lastPublishedMinute else {
            self.lastPublishedMinute = minuteIndex
            return true
        }

        guard minuteIndex > lastPublishedMinute,
              minuteIndex - lastPublishedMinute >= minimumIntervalMinutes
        else {
            return false
        }

        self.lastPublishedMinute = minuteIndex
        return true
    }
}
