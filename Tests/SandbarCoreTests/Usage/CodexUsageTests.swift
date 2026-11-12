import Foundation
import SandbarCore
import Testing

struct CodexUsageTests {
    static let primary = #"{"usedPercent": 41, "windowDurationMins": 300, "resetsAt": 1794520800}"#
    static let secondary = #"{"usedPercent": 17, "windowDurationMins": 10080, "resetsAt": 1795100000}"#

    static func answer(primary: String?, secondary: String?) -> Data {
        let windows = [primary.map { "\"primary\": \($0)" }, secondary.map { "\"secondary\": \($0)" }]
        return Data(
            """
            {"ordinaryUsageAllowed": true, "rateLimits": {"limitId": "codex", "limitName": null, \
            \(windows.compactMap { $0 }.joined(separator: ", ")), "planType": "pro", "rateLimitReachedType": null}, \
            "accountId": "acct"}
            """.utf8)
    }

    func server(answeringRateLimits answer: String) throws -> URL {
        try FakeTool.script(
            named: "codex-app-server",
            #"""
            while read -r line; do
              id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
              case "$line" in
                *'"method":"initialize"'*) echo "{\"id\":$id,\"result\":{\"userAgent\":\"fake\"}}" ;;
                *'"method":"account/rateLimits/read"'*) \#(answer) ;;
              esac
            done
            """#
        )
    }

    @Test func bothWindowsAreRead() throws {
        let limits = try CodexUsage.limits(inAnswer: Self.answer(primary: Self.primary, secondary: Self.secondary))
        #expect(limits.map(\.label) == ["5h", "Week"])
        #expect(limits.map(\.used) == [0.41, 0.17])
        #expect(
            limits.map(\.resetsAt) == [
                Date(timeIntervalSince1970: 1_794_520_800), Date(timeIntervalSince1970: 1_795_100_000),
            ])
    }

    @Test func aSingleWindowIsRead() throws {
        let limits = try CodexUsage.limits(inAnswer: Self.answer(primary: nil, secondary: Self.secondary))
        #expect(limits.map(\.label) == ["Week"])
    }

    @Test func anotherWindowIsNamedByItsHours() throws {
        let window = Self.secondary.replacing("10080", with: "43200")
        let limits = try CodexUsage.limits(inAnswer: Self.answer(primary: nil, secondary: window))
        #expect(limits.map(\.label) == ["720h"])
    }

    @Test func anAnswerWithoutRateLimitsIsNotUnderstood() {
        let answer = #"{"accountId": "acct"}"#
        #expect(throws: ToolError.notUnderstood(answer)) {
            try CodexUsage.limits(inAnswer: Data(answer.utf8))
        }
    }

    @Test func theServerIsAskedAndHearsTheEnvironment() async throws {
        let tool = try server(
            answeringRateLimits: """
                used=$(basename "$CODEX_HOME")
                echo "{\\"id\\":$id,\\"result\\":{\\"rateLimits\\":{\\"primary\\":{\\"usedPercent\\":$used,\\"windowDurationMins\\":300,\\"resetsAt\\":1794520800}}}}"
                """)
        let limits = try await CodexUsage.limits(tool: tool, environment: ["CODEX_HOME": "/profiles/work/58"])
        #expect(limits.map(\.used) == [0.58])
    }

    @Test func aSignedOutAccountIsReported() async throws {
        let tool = try server(
            answeringRateLimits: #"""
                echo "{\"id\":$id,\"error\":{\"code\":-32600,\"message\":\"codex account authentication required to read rate limits\"}}"
                """#)
        await #expect(throws: ToolError.signedOut) {
            try await CodexUsage.limits(tool: tool, environment: [:])
        }
    }

    @Test func aServerThatNeverAnswersTimesOut() async throws {
        let tool = try server(answeringRateLimits: ":")
        await #expect(throws: ToolError.timedOut) {
            try await CodexUsage.limits(tool: tool, environment: [:], timeout: .milliseconds(300))
        }
    }
}
