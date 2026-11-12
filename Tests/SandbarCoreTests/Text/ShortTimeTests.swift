import Foundation
import SandbarCore
import Testing

struct ShortTimeTests {
    static let now = Date(timeIntervalSince1970: 1_794_506_400)  // 2026-11-12 18:00 UTC
    static let leftCases: [(seconds: Double, text: String)] = [
        (1_674_120, "19d9h"), (172_800, "2d0h"), (11_480, "3h12m"), (3_600, "1h0m"),
        (2_820, "47m"), (20, "1m"), (0, "0m"), (-60, "0m"),
    ]
    static let ageCases: [(seconds: Double, text: String)] = [
        (20, "1m"), (300, "5m"), (3_599, "59m"), (10_800, "3h"), (169_200, "1d"), (172_800, "2d"),
        (2_505_600, "29d"), (2_592_000, "1mo"), (31_449_600, "12mo"), (31_536_000, "1y"),
        (69_120_000, "2y"), (-30, "1m"),
    ]
    static let spokenCases: [(time: String, words: String)] = [
        ("19d9h", "19 days 9 hours"), ("1d1h", "1 day 1 hour"), ("2d0h", "2 days"), ("3h12m", "3 hours 12 minutes"),
        ("1h0m", "1 hour"), ("47m", "47 minutes"), ("1m", "1 minute"), ("0m", "0 minutes"), ("3d", "3 days"),
        ("1mo", "1 month"), ("12mo", "12 months"), ("1y", "1 year"), ("2y", "2 years"),
    ]

    @Test(arguments: leftCases) func timeLeft(seconds: Double, text: String) {
        #expect(ShortTime.left(until: Self.now + seconds, from: Self.now) == text)
    }

    @Test(arguments: ageCases) func age(seconds: Double, text: String) {
        #expect(ShortTime.age(since: Self.now - seconds, to: Self.now) == text)
    }

    @Test(arguments: spokenCases) func spoken(time: String, words: String) {
        #expect(ShortTime.spoken(time) == words)
    }
}
