import Foundation
import SandbarCore
import Testing

struct CodexServerTests {
    struct AccountAnswer: Decodable, Sendable, Equatable {
        struct Account: Decodable, Sendable, Equatable {
            var type: String
        }
        var account: Account?
        var requiresOpenaiAuth: Bool
    }

    struct Updated: Decodable, Equatable {
        var plan: String
    }

    struct Argument: Decodable, Sendable {
        var argument: String
    }

    static let startCases: [(name: String, argument: String)] = [("codex", "app-server"), ("codex-app-server", "")]
    static let accountRead = ["refreshToken": false]

    func server(named name: String = "codex-app-server", answeringAccountRead answer: String) throws -> URL {
        try FakeTool.script(
            named: name,
            """
            while read -r line; do
              id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
              case "$line" in
                *'"method":"initialize"'*) echo "{\\"id\\":$id,\\"result\\":{\\"userAgent\\":\\"fake\\"}}" ;;
                *'"method":"account/read"'*) \(answer) ;;
              esac
            done
            """
        )
    }

    @Test func anAnswerArrivesAfterANotice() async throws {
        let tool = try server(
            answeringAccountRead: """
                echo '{"method":"account/updated","params":{"plan":"plus"}}'; \
                echo "{\\"id\\":$id,\\"result\\":{\\"account\\":null,\\"requiresOpenaiAuth\\":true}}"
                """
        )
        let server = try await CodexServer(tool: tool, environment: [:])
        let answer: AccountAnswer = try await server.ask("account/read", Self.accountRead)
        #expect(answer == AccountAnswer(account: nil, requiresOpenaiAuth: true))
        var notices = server.notices.makeAsyncIterator()
        let notice = try #require(await notices.next())
        #expect(notice.method == "account/updated")
        #expect(try JSONDecoder().decode(Updated.self, from: notice.parameters) == Updated(plan: "plus"))
        await server.stop()
    }

    @Test func anErrorAnswerFails() async throws {
        let tool = try server(
            answeringAccountRead: """
                echo "{\\"id\\":$id,\\"error\\":{\\"code\\":-32600,\\"message\\":\\"authentication required\\"}}"
                """
        )
        let server = try await CodexServer(tool: tool, environment: [:])
        await #expect(throws: ToolError.failed(status: -32600, output: "authentication required")) {
            let _: AccountAnswer = try await server.ask("account/read", Self.accountRead)
        }
        await server.stop()
    }

    @Test func aServerThatExitsWithoutAnsweringFails() async throws {
        let server = try await CodexServer(tool: try server(answeringAccountRead: "exit 2"), environment: [:])
        await #expect(throws: ToolError.failed(status: 2, output: "")) {
            let _: AccountAnswer = try await server.ask("account/read", Self.accountRead)
        }
    }

    @Test func aServerThatNeverAnswersTimesOut() async throws {
        let tool = try server(answeringAccountRead: ":")
        let server = try await CodexServer(tool: tool, environment: [:], timeout: .milliseconds(300))
        let start = ContinuousClock.now
        await #expect(throws: ToolError.timedOut) {
            let _: AccountAnswer = try await server.ask("account/read", Self.accountRead)
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test(arguments: startCases) func theToolIsStartedByItsName(name: String, argument: String) async throws {
        let tool = try server(
            named: name, answeringAccountRead: #"echo "{\"id\":$id,\"result\":{\"argument\":\"$1\"}}""#)
        let server = try await CodexServer(tool: tool, environment: [:])
        let answer: Argument = try await server.ask("account/read", Self.accountRead)
        #expect(answer.argument == argument)
        await server.stop()
    }
}
