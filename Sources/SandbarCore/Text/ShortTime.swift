import Foundation

package enum ShortTime {
    package static func left(until end: Date, from now: Date) -> String {
        let minutes = max(0, Int((end.timeIntervalSince(now) / 60).rounded(.up)))
        let days = minutes / 1_440
        let hours = minutes / 60 % 24
        let minutesOfHour = minutes % 60
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

    /// A time written by `left` or `age`, in words for a screen reader: "19d9h" is "19 days 9 hours".
    package static func spoken(_ time: String) -> String {
        let parts = time.matches(of: #/(\d+)(mo|[ydhm])/#)
        return
            parts
            .filter { $0.1 != "0" || parts.count == 1 }
            .map { part in
                let unit =
                    switch part.2 {
                    case "y": "year"
                    case "mo": "month"
                    case "d": "day"
                    case "h": "hour"
                    default: "minute"
                    }
                return "\(part.1) \(unit)\(part.1 == "1" ? "" : "s")"
            }
            .joined(separator: " ")
    }
}
