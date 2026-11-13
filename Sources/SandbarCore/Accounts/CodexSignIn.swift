import Foundation

package enum CodexSignIn {
    package struct Pending: Sendable {
        package var address: URL
        fileprivate let server: CodexServer
        fileprivate let loginID: String

        package func finished() async throws {
            struct Completed: Decodable {
                var loginId: String?
                var success: Bool
                var error: String?
            }
            for await notice in server.notices where notice.method == "account/login/completed" {
                let completed: Completed
                do {
                    completed = try JSONDecoder().decode(Completed.self, from: notice.parameters)
                } catch is DecodingError {
                    await server.stop()
                    throw ToolError.notUnderstood(String(decoding: notice.parameters.prefix(2_000), as: UTF8.self))
                }
                guard completed.loginId == loginID else { continue }
                await server.stop()
                guard completed.success else { throw ToolError.failed(status: 1, output: completed.error ?? "") }
                return
            }
            await server.stop()
            try Task.checkCancellation()
            throw ToolError.failed(status: 1, output: "")
        }

        package func cancel() async {
            struct Cancel: Encodable, Sendable { var loginId: String }
            let _: Empty? = try? await server.ask(  // stopping the server ends the sign-in whatever this answers
                "account/login/cancel", Cancel(loginId: loginID))
            await server.stop()
        }
    }

    package static func status(
        tool: URL, environment: [String: String], timeout: Duration = .seconds(30)
    ) async throws -> AccountStatus {
        struct Answer: Decodable, Sendable {
            struct Account: Decodable, Sendable {
                var planType: String?
                var workspaceName: String?
            }
            var account: Account?
        }
        let answer: Answer = try await ask(
            tool: tool, environment: environment, timeout: timeout, "account/read", ["refreshToken": false])
        return AccountStatus(
            isSignedIn: answer.account != nil, organization: answer.account?.workspaceName,
            planWord: answer.account?.planType)
    }

    package static func begin(tool: URL, environment: [String: String]) async throws -> Pending {
        struct Started: Decodable, Sendable {
            var loginId: String
            var authUrl: URL
        }
        let server = try await CodexServer(tool: tool, environment: environment)
        do {
            let started: Started = try await server.ask("account/login/start", ["type": "chatgpt"])
            return Pending(address: started.authUrl, server: server, loginID: started.loginId)
        } catch {
            await server.stop()
            throw error
        }
    }

    package static func signOut(tool: URL, environment: [String: String]) async throws {
        let _: Empty = try await ask(
            tool: tool, environment: environment, timeout: .seconds(30), "account/logout", Never?.none)
    }

    private struct Empty: Decodable, Sendable {}

    private static func ask<Answer: Decodable & Sendable>(
        tool: URL, environment: [String: String], timeout: Duration, _ method: String,
        _ parameters: some Encodable & Sendable
    ) async throws -> Answer {
        let server = try await CodexServer(tool: tool, environment: environment, timeout: timeout)
        do {
            let answer: Answer = try await server.ask(method, parameters)
            await server.stop()
            return answer
        } catch {
            await server.stop()
            throw error
        }
    }
}
