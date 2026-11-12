import Foundation
import SandbarCore
import Testing

struct ClaudeUsageTests {
    static let noExtraUsage =
        #"{"is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null, "currency": null}"#
    static let paidByUse =
        #"{"is_enabled": true, "monthly_limit": 500000, "used_credits": 312055, "utilization": 62.411, "currency": "USD"}"#
    static let weeklyAll =
        #"{"kind": "weekly_all", "group": "weekly", "percent": 37, "resets_at": "2026-11-15T22:00:00.323361+00:00", "scope": null, "severity": "normal", "is_active": true}"#
    static let weeklyFable =
        #"{"kind": "weekly_scoped", "group": "weekly", "percent": 12, "resets_at": "2026-11-15T22:00:00.323524+00:00", "scope": {"model": {"display_name": "Fable"}, "surface": null}, "severity": "normal", "is_active": false}"#

    static func output(limits: [String], extraUsage: String) -> Data {
        Data(
            """
            {"type":"system","subtype":"init"}
            {"type":"assistant","message":{"role":"assistant"},"usage_report":{"session":{"total_cost_usd":0},"rate_limits":{"limits":[\(limits.joined(separator: ","))],"extra_usage":\(extraUsage)}}}
            {"type":"result","subtype":"success"}

            """.utf8)
    }

    func claude(_ body: String) throws -> URL {
        try FakeTool.script(named: "claude", body)
    }

    @Test func aSeatPaidByUseGivesTheMonthlyBudget() throws {
        let limits = try ClaudeUsage.limits(inReport: Self.output(limits: [], extraUsage: Self.paidByUse))
        #expect(limits == [UsageLimit(window: .month, model: nil, used: 0.62411, dollars: 3120, resetsAt: nil)])
    }

    @Test func aPlanWithWeeklyLimitsKeepsTheirOrder() throws {
        let limits = try ClaudeUsage.limits(
            inReport: Self.output(limits: [Self.weeklyAll, Self.weeklyFable], extraUsage: Self.noExtraUsage))
        #expect(limits.map(\.label) == ["Week", "Fable"])
        #expect(limits.map(\.used) == [0.37, 0.12])
        let reset = try #require(limits[0].resetsAt)
        #expect(abs(reset.timeIntervalSince1970 - 1_794_780_000.323) < 0.001)
    }

    @Test func theMonthlyBudgetFollowsTheLimits() throws {
        let limits = try ClaudeUsage.limits(
            inReport: Self.output(limits: [Self.weeklyAll], extraUsage: Self.paidByUse))
        #expect(limits.map(\.label) == ["Week", "Month"])
    }

    @Test func nothingEnabledAndNoLimitsGivesNothing() throws {
        #expect(try ClaudeUsage.limits(inReport: Self.output(limits: [], extraUsage: Self.noExtraUsage)) == [])
    }

    @Test func anUnknownGroupIsKept() throws {
        let limit = Self.weeklyAll.replacing(#""weekly""#, with: #""mystery_group""#)
        let limits = try ClaudeUsage.limits(inReport: Self.output(limits: [limit], extraUsage: Self.noExtraUsage))
        #expect(limits.map(\.window) == [.other("mystery_group")])
    }

    @Test(arguments: [("five_hour", UsageLimit.Window.fiveHours), ("session", .fiveHours)])
    func theShortWindowGroups(group: String, window: UsageLimit.Window) throws {
        let limit = Self.weeklyAll.replacing(#""weekly""#, with: "\"\(group)\"")
        let limits = try ClaudeUsage.limits(inReport: Self.output(limits: [limit], extraUsage: Self.noExtraUsage))
        #expect(limits.map(\.window) == [window])
    }

    @Test func aMissingResetIsKept() throws {
        let limit = Self.weeklyAll.replacing(#""2026-11-15T22:00:00.323361+00:00""#, with: "null")
        let limits = try ClaudeUsage.limits(inReport: Self.output(limits: [limit], extraUsage: Self.noExtraUsage))
        #expect(limits.map(\.resetsAt) == [nil])
    }

    @Test func aResetWithoutDecimalsIsRead() throws {
        let limit = Self.weeklyAll.replacing(".323361", with: "")
        let limits = try ClaudeUsage.limits(inReport: Self.output(limits: [limit], extraUsage: Self.noExtraUsage))
        #expect(limits.map(\.resetsAt) == [Date(timeIntervalSince1970: 1_794_780_000)])
    }

    @Test func aShareAboveTheWholeIsKept() throws {
        let limit = Self.weeklyAll.replacing(#""percent": 37"#, with: #""percent": 104"#)
        let limits = try ClaudeUsage.limits(inReport: Self.output(limits: [limit], extraUsage: Self.noExtraUsage))
        #expect(limits.map(\.used) == [1.04])
    }

    @Test func aLimitWithoutAShareIsNotUnderstood() {
        let limit = Self.weeklyAll.replacing(#""percent": 37, "#, with: "")
        #expect(throws: ToolError.self) {
            try ClaudeUsage.limits(inReport: Self.output(limits: [limit], extraUsage: Self.noExtraUsage))
        }
    }

    @Test func outputWithoutAReportIsNotUnderstood() {
        let printed = #"{"type":"system"}"# + "\n" + #"{"type":"result"}"# + "\n"
        #expect(throws: ToolError.notUnderstood(printed)) {
            try ClaudeUsage.limits(inReport: Data(printed.utf8))
        }
    }

    @Test func onlyTheEndOfLongOutputIsQuoted() {
        let printed = String(repeating: "x", count: 5_000) + "END"
        #expect(throws: ToolError.notUnderstood(String(printed.suffix(2_000)))) {
            try ClaudeUsage.limits(inReport: Data(printed.utf8))
        }
    }

    @Test func theToolIsAskedForItsUsageAndHearsTheEnvironment() async throws {
        let tool = try claude(
            """
            [ "$*" = "--safe-mode --no-session-persistence -p /usage --output-format stream-json --verbose" ] || exit 64
            percent=$(basename "$CLAUDE_CONFIG_DIR")
            echo '{"type":"system"}'
            echo "{\\"type\\":\\"assistant\\",\\"usage_report\\":{\\"rate_limits\\":{\\"limits\\":[{\\"group\\":\\"weekly\\",\\"percent\\":$percent,\\"resets_at\\":null,\\"scope\\":null}],\\"extra_usage\\":{\\"is_enabled\\":false}}}}"
            """)
        let limits = try await ClaudeUsage.limits(tool: tool, environment: ["CLAUDE_CONFIG_DIR": "/profiles/work/58"])
        #expect(limits.map(\.used) == [0.58])
    }

    @Test func aToolThatPrintsNothingIsNotUnderstood() async throws {
        let tool = try claude(":")
        await #expect(throws: ToolError.notUnderstood("")) {
            try await ClaudeUsage.limits(tool: tool, environment: [:])
        }
    }

    @Test func aToolThatSleepsTimesOut() async throws {
        let tool = try claude("sleep 30")
        await #expect(throws: ToolError.timedOut) {
            try await ClaudeUsage.limits(tool: tool, environment: [:], timeout: .milliseconds(300))
        }
    }
}
