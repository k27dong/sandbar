import Foundation
import SandbarCore
import Testing

struct CodexSignInTests {
    static let address = "https://auth.openai.example/oauth/authorize?state=abc"

    func server(answering answers: String) throws -> URL {
        try FakeTool.script(
            named: "codex-app-server",
            """
            while read -r line; do
              id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
              case "$line" in
                *'"method":"initialize"'*) echo "{\\"id\\":$id,\\"result\\":{\\"userAgent\\":\\"fake\\"}}" ;;
                \(answers)
              esac
            done
            """
        )
    }

    func signInServer(completing completion: String = ":") throws -> URL {
        try server(
            answering: """
                *'"method":"account/login/start"'*'"type":"chatgpt"'*)
                  echo "{\\"id\\":$id,\\"result\\":{\\"type\\":\\"chatgpt\\",\\"loginId\\":\\"login-1\\",\\"authUrl\\":\\"\(Self.address)\\"}}"
                  \(completion) ;;
                *'"method":"account/login/cancel"'*)
                  printf '%s\\n' "$line" > "$(dirname "$0")/cancelled"
                  echo "{\\"id\\":$id,\\"result\\":{\\"status\\":\\"canceled\\"}}" ;;
                """
        )
    }

    @Test func noAccountIsSignedOut() async throws {
        let tool = try server(
            answering: """
                *'"method":"account/read"'*'"refreshToken":false'*)
                  echo "{\\"id\\":$id,\\"result\\":{\\"account\\":null,\\"requiresOpenaiAuth\\":true}}" ;;
                """
        )
        let status = try await CodexSignIn.status(tool: tool, environment: [:])
        #expect(status == AccountStatus(isSignedIn: false, organization: nil, plan: nil))
    }

    @Test func anAccountGivesItsWorkspaceAndPlan() async throws {
        let tool = try server(
            answering: """
                *'"method":"account/read"'*'"refreshToken":false'*)
                  echo "{\\"id\\":$id,\\"result\\":{\\"account\\":{\\"type\\":\\"chatgpt\\",\\"planType\\":\\"team\\",\\"workspaceName\\":\\"Acme\\"},\\"requiresOpenaiAuth\\":true}}" ;;
                """
        )
        let status = try await CodexSignIn.status(tool: tool, environment: [:])
        #expect(status == AccountStatus(isSignedIn: true, organization: "Acme", plan: "Team"))
    }

    @Test func signingInGivesTheAddress() async throws {
        let pending = try await CodexSignIn.begin(tool: try signInServer(), environment: [:])
        #expect(pending.address == URL(string: Self.address))
        await pending.cancel()
    }

    @Test func signingInFinishesWithTheCompletionNotice() async throws {
        let tool = try signInServer(
            completing: """
                echo '{"method":"account/updated","params":{}}'
                  echo '{"method":"account/login/completed","params":{"loginId":"login-0","success":false,"error":"other"}}'
                  echo '{"method":"account/login/completed","params":{"loginId":"login-1","success":true,"error":null}}'
                """
        )
        let pending = try await CodexSignIn.begin(tool: tool, environment: [:])
        try await pending.finished()
    }

    @Test func aFailedSignInFails() async throws {
        let tool = try signInServer(
            completing: """
                echo '{"method":"account/login/completed","params":{"loginId":"login-1","success":false,"error":"denied"}}'
                """
        )
        let pending = try await CodexSignIn.begin(tool: tool, environment: [:])
        await #expect(throws: ToolError.failed(status: 1, output: "denied")) { try await pending.finished() }
    }

    @Test func cancellingReachesTheTool() async throws {
        let tool = try signInServer()
        let pending = try await CodexSignIn.begin(tool: tool, environment: [:])
        await pending.cancel()
        let cancelled = try String(
            contentsOf: tool.deletingLastPathComponent().appending(path: "cancelled"), encoding: .utf8)
        #expect(cancelled.contains(#""method":"account/login/cancel","params":{"loginId":"login-1"}"#))
    }
}
