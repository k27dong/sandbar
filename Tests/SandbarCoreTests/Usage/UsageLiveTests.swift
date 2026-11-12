import Foundation
import SandbarCore
import Testing

@Suite(.enabled(if: Live.isOn)) struct UsageLiveTests {
    func print(_ limits: [UsageLimit]) {
        for limit in limits {
            let left = limit.end(now: .now).map { ShortTime.left(until: $0, from: .now) } ?? "-"
            Swift.print("usage row: \(limit.label) \(limit.amount) \(left)")
        }
    }

    @Test func claudeGivesTheMonthlyBudget() async throws {
        let limits = try await ClaudeUsage.limits(tool: Live.program("SANDBAR_LIVE_CLAUDE"), environment: [:])
        print(limits)
        let limit = try #require(limits.first)
        #expect(limits.count == 1)
        #expect(limit.window == .month)
        #expect(limit.dollars != nil)
        #expect((0...1.5).contains(limit.used))
    }

    @Test func codexGivesTheFiveHourAndWeekLimits() async throws {
        let limits = try await CodexUsage.limits(tool: Live.program("SANDBAR_LIVE_CODEX"), environment: [:])
        print(limits)
        #expect(limits.map(\.label) == ["5h", "Week"])
    }
}
