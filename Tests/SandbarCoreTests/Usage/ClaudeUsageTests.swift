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

    static let shortWindowCases: [(group: String, window: UsageLimit.Window)] = [
        ("five_hour", .fiveHours), ("session", .fiveHours),
    ]

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

    @Test func limitsKeepTheirOrderWhateverTheirShares() throws {
        let fable = Self.weeklyFable.replacing(#""percent": 12"#, with: #""percent": 62"#)
        let limits = try ClaudeUsage.limits(
            inReport: Self.output(limits: [Self.weeklyAll, fable], extraUsage: Self.noExtraUsage))
        #expect(limits.map(\.used) == [0.37, 0.62])
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

    @Test(arguments: shortWindowCases) func theShortWindowGroups(group: String, window: UsageLimit.Window) throws {
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

    @Test func aResetThatIsNoTimeIsNotUnderstood() {
        let limit = Self.weeklyAll.replacing(#""2026-11-15T22:00:00.323361+00:00""#, with: #""next Tuesday""#)
        let printed = Self.output(limits: [limit], extraUsage: Self.noExtraUsage)
        #expect(throws: ToolError.notUnderstood(String(decoding: printed, as: UTF8.self))) {
            try ClaudeUsage.limits(inReport: printed)
        }
    }

    @Test func aShareAboveTheWholeIsKept() throws {
        let limit = Self.weeklyAll.replacing(#""percent": 37"#, with: #""percent": 104"#)
        let limits = try ClaudeUsage.limits(inReport: Self.output(limits: [limit], extraUsage: Self.noExtraUsage))
        #expect(limits.map(\.used) == [1.04])
    }

    @Test func aLimitWithoutAShareIsNotUnderstood() {
        let limit = Self.weeklyAll.replacing(#""percent": 37, "#, with: "")
        let printed = Self.output(limits: [limit], extraUsage: Self.noExtraUsage)
        #expect(throws: ToolError.notUnderstood(String(decoding: printed, as: UTF8.self))) {
            try ClaudeUsage.limits(inReport: printed)
        }
    }

    @Test func aBudgetOfZeroGivesNoMonth() throws {
        let extra = Self.paidByUse.replacing(#""monthly_limit": 500000"#, with: #""monthly_limit": 0"#)
        #expect(try ClaudeUsage.limits(inReport: Self.output(limits: [], extraUsage: extra)) == [])
    }

    @Test func aBudgetWithoutWhatWasSpentIsNotUnderstood() {
        let extra = Self.paidByUse.replacing(#""used_credits": 312055"#, with: #""used_credits": null"#)
        let printed = Self.output(limits: [], extraUsage: extra)
        #expect(throws: ToolError.notUnderstood(String(decoding: printed, as: UTF8.self))) {
            try ClaudeUsage.limits(inReport: printed)
        }
    }

    @Test func aBudgetThatIsNotEnabledGivesNoMonth() throws {
        let extra = Self.paidByUse.replacing(#""is_enabled": true"#, with: #""is_enabled": false"#)
        #expect(try ClaudeUsage.limits(inReport: Self.output(limits: [], extraUsage: extra)) == [])
    }

    @Test func strayTextLinesAroundTheReportAreSkipped() throws {
        let report = String(
            decoding: Self.output(limits: [Self.weeklyAll], extraUsage: Self.noExtraUsage), as: UTF8.self)
        let limits = try ClaudeUsage.limits(inReport: Data(("warming up\n" + report + "done\n").utf8))
        #expect(limits.map(\.label) == ["Week"])
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
            [ $# -eq 7 ] && [ "$1" = "--safe-mode" ] && [ "$2" = "--no-session-persistence" ] && [ "$3" = "-p" ] \\
              && [ "$4" = "/usage" ] && [ "$5" = "--output-format" ] && [ "$6" = "stream-json" ] \\
              && [ "$7" = "--verbose" ] || exit 64
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

    @Test func aToolThatFailsWithoutAReportReportsWhatItComplained() async throws {
        let tool = try claude("echo printed; echo refused >&2; exit 3")
        await #expect(throws: ToolError.failed(status: 3, output: "refused\n")) {
            try await ClaudeUsage.limits(tool: tool, environment: [:])
        }
    }

    @Test func aToolThatFailsSilentlyReportsWhatItPrinted() async throws {
        let tool = try claude("echo printed; exit 4")
        await #expect(throws: ToolError.failed(status: 4, output: "printed\n")) {
            try await ClaudeUsage.limits(tool: tool, environment: [:])
        }
    }

    @Test func aMalformedReportIsNotUnderstoodWhateverTheExitStatus() async throws {
        let limit = Self.weeklyAll.replacing(#""percent": 37, "#, with: "")
        let printed = String(decoding: Self.output(limits: [limit], extraUsage: Self.noExtraUsage), as: UTF8.self)
        let tool = try claude("cat <<'EOF'\n\(printed)EOF\nexit 1")
        await #expect(throws: ToolError.notUnderstood(printed)) {
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
