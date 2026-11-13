import Foundation

package struct UsageLimit: Codable, Hashable, Sendable {
    package enum Window: Codable, Hashable, Sendable {
        case fiveHours, week, month
        case other(String)
    }

    package enum Level: Sendable {
        case normal, near, full
    }

    package var window: Window
    package var model: String?
    package var used: Double
    package var dollars: Int?
    package var resetsAt: Date?

    package init(window: Window, model: String? = nil, used: Double, dollars: Int? = nil, resetsAt: Date? = nil) {
        self.window = window
        self.model = model
        self.used = used
        self.dollars = dollars
        self.resetsAt = resetsAt
    }

    package var label: String {
        if let model { return model }
        switch window {
        case .fiveHours: return "5h"
        case .week: return "Week"
        case .month: return "Month"
        case .other(let name):
            let words = name.replacing("_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    package var amount: String {
        if let dollars { return "$\(dollars)" }
        return "\(Int((used * 100).rounded()))%"
    }

    package var level: Level {
        if used >= 1 { return .full }
        if used >= 0.8 { return .near }
        return .normal
    }

    package func end(now: Date) -> Date? {
        resetsAt ?? (window == .month ? Self.utcMonth(containing: now).end : nil)
    }

    package func pace(now: Date) -> Double? {
        let length: TimeInterval
        switch window {
        case .fiveHours: length = 5 * 3_600
        case .week: length = 7 * 86_400
        case .month:
            let month = Self.utcMonth(containing: now)
            length = month.end.timeIntervalSince(month.start)
        case .other: return nil
        }
        guard let end = end(now: now) else { return nil }
        return min(1, max(0, 1 - end.timeIntervalSince(now) / length))
    }

    private static func utcMonth(containing date: Date) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let month = calendar.dateInterval(of: .month, for: date)!
        return (month.start, month.end)
    }
}
