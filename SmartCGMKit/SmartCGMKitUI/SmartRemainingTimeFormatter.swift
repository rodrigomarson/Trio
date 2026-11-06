import Foundation
enum SmartRemainingTimeFormatter {
    static func format(until expiresAt: Date, now: Date = Date()) -> String {
        let remaining = max(0, expiresAt.timeIntervalSince(now))
        let totalMinutes = Int(remaining) / 60
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        let d = String(localized: "d", comment: "Abbreviation for Days")
        let h = String(localized: "h", comment: "Abbreviation for Hours")
        let m = String(localized: "m", comment: "Abbreviation for Minutes")
        if days > 0, hours > 0 { return "\(days)\(d) \(hours)\(h)" }
        if days > 0 { return "\(days)\(d)" }
        if hours > 0 { return "\(hours)\(h)" }
        if minutes > 0 { return "\(minutes)\(m)" }
        return "<" + "\u{00A0}" + "1" + "\u{00A0}" + m
    }
}

extension TimeInterval {
    static func minutes(_ value: Double) -> TimeInterval { value * 60 }
    static func hours(_ value: Double) -> TimeInterval { value * 3600 }
}
