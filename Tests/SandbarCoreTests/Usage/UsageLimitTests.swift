import Foundation
import SandbarCore
import Testing

struct UsageLimitTests {
    static let labelCases: [(limit: UsageLimit, label: String)] = [
        (UsageLimit(window: .fiveHours, used: 0.1), "5h"),
        (UsageLimit(window: .week, used: 0.1), "Week"),
        (UsageLimit(window: .month, used: 0.1), "Month"),
        (UsageLimit(window: .week, model: "Fable", used: 0.1), "Fable"),
        (UsageLimit(window: .other("mystery_group"), used: 0.1), "Mystery group"),
    ]
    static let amountCases: [(limit: UsageLimit, amount: String)] = [
        (UsageLimit(window: .week, used: 0.41), "41%"),
        (UsageLimit(window: .week, used: 1.04), "104%"),
        (UsageLimit(window: .month, used: 0.62, dollars: 3120), "$3120"),
        (UsageLimit(window: .month, used: 0.62, dollars: 12345), "$12345"),
    ]
    static let levelCases: [(used: Double, level: UsageLimit.Level)] = [
        (0.79, .normal), (0.80, .near), (1.0, .full), (1.3, .full),
    ]
    static let startOfNovember11 = Sample.now - 151_200
    static let paceCases: [(limit: UsageLimit, now: Date, pace: Double?)] = [
        (UsageLimit(window: .week, used: 0, resetsAt: Sample.now + 3.5 * 86_400), Sample.now, 0.5),
        (UsageLimit(window: .fiveHours, used: 0, resetsAt: Sample.now + 3_600), Sample.now, 0.8),
        (UsageLimit(window: .month, used: 0), startOfNovember11, 1.0 / 3),
        (UsageLimit(window: .week, used: 0, resetsAt: Sample.now - 60), Sample.now, 1),
        (UsageLimit(window: .other("mystery_group"), used: 0, resetsAt: Sample.now + 3_600), Sample.now, nil),
        (UsageLimit(window: .week, used: 0), Sample.now, nil),
    ]

    @Test(arguments: labelCases) func label(limit: UsageLimit, label: String) {
        #expect(limit.label == label)
    }

    @Test(arguments: amountCases) func amount(limit: UsageLimit, amount: String) {
        #expect(limit.amount == amount)
    }

    @Test(arguments: levelCases) func level(used: Double, level: UsageLimit.Level) {
        #expect(UsageLimit(window: .week, used: used).level == level)
    }

    @Test func aMonthWithoutAResetEndsAtTheStartOfTheNextMonthInUTC() throws {
        let end = try #require(UsageLimit(window: .month, used: 0.5).end(now: Sample.now))
        #expect(end == Date(timeIntervalSince1970: 1_796_083_200))  // 2026-12-01 00:00 UTC
        #expect(ShortTime.left(until: end, from: Sample.now) == "18d6h")
    }

    @Test func theEndIsTheReportedReset() {
        let reset = Sample.now + 7_200
        #expect(UsageLimit(window: .month, used: 0.5, resetsAt: reset).end(now: Sample.now) == reset)
        #expect(UsageLimit(window: .week, used: 0.5).end(now: Sample.now) == nil)
    }

    @Test(arguments: paceCases) func pace(limit: UsageLimit, now: Date, pace: Double?) throws {
        guard let expected = pace else {
            #expect(limit.pace(now: now) == nil)
            return
        }
        let actual = try #require(limit.pace(now: now))
        #expect(abs(actual - expected) < 1e-9)
    }
}
