import Foundation

package enum ShortTime {
    package static func left(until end: Date, from now: Date) -> String {
        let minutes = max(0, Int((end.timeIntervalSince(now) / 60).rounded(.up)))
        let (days, hours, minutesOfHour) = (minutes / 1_440, minutes / 60 % 24, minutes % 60)
        if days > 0 { return "\(days)d\(hours)h" }
        if hours > 0 { return "\(hours)h\(minutesOfHour)m" }
        return "\(minutes)m"
    }

    package static func age(since start: Date, to now: Date) -> String {
        let minutes = max(1, Int(now.timeIntervalSince(start) / 60))
        let days = minutes / 1_440
        if days >= 365 { return "\(days / 365)y" }
        if days >= 30 { return "\(days / 30)mo" }
        if days > 0 { return "\(days)d" }
        if minutes >= 60 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}
