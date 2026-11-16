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

    @Test func claudeGivesTheLimitsOfItsPlan() async throws {
        let limits = try await ClaudeUsage.limits(tool: Live.program("SANDBAR_LIVE_CLAUDE"), environment: [:])
        print(limits)
        #expect(!limits.isEmpty)
        #expect(limits.allSatisfy { (0...1.5).contains($0.used) })
        #expect(limits.allSatisfy { $0.window != .month || $0.dollars != nil }, "a monthly budget is in dollars")
    }

    @Test func codexGivesTheFiveHourAndWeekLimits() async throws {
        let limits = try await CodexUsage.limits(tool: Live.program("SANDBAR_LIVE_CODEX"), environment: [:])
        print(limits)
        #expect(limits.map(\.label) == ["5h", "Week"])
    }
}
