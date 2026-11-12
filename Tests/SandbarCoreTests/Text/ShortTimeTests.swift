import Foundation
import Testing

@testable import SandbarCore

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

    @Test(arguments: leftCases) func timeLeft(seconds: Double, text: String) {
        #expect(ShortTime.left(until: Self.now + seconds, from: Self.now) == text)
    }

    @Test(arguments: ageCases) func age(seconds: Double, text: String) {
        #expect(ShortTime.age(since: Self.now - seconds, to: Self.now) == text)
    }
}
