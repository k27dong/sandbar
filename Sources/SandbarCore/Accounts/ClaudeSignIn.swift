import Foundation

package enum ClaudeSignIn {
    package static func status(
        tool: URL, environment: [String: String], timeout: Duration = .seconds(30)
    ) async throws -> AccountStatus {
        struct Status: Decodable {
            var loggedIn: Bool
            var orgName: String?
            var subscriptionType: String?
        }
        let output = try await Command.run(tool, ["auth", "status"], environment: environment, timeout: timeout)
        let status: Status
        do {
            status = try JSONDecoder().decode(Status.self, from: output.standardOutput)  // signed out exits 1 with JSON
        } catch is DecodingError {
            throw ToolError.notUnderstood(String(decoding: output.standardOutput.prefix(2_000), as: UTF8.self))
        }
        return AccountStatus(
            isSignedIn: status.loggedIn, organization: status.orgName, planWord: status.subscriptionType)
    }

    package static func begin(tool: URL, environment: [String: String]) throws -> Command.Running {
        try Command.start(tool, ["auth", "login"], environment: environment)
    }

    package static func address(in line: String) -> URL? {
        guard let start = line.range(of: "https://") else { return nil }
        return URL(string: String(line[start.lowerBound...].prefix { !$0.isWhitespace }))
    }

    package static func signOut(tool: URL, environment: [String: String]) async throws {
        let output = try await Command.run(tool, ["auth", "logout"], environment: environment)
        guard output.status == 0 else {
            throw ToolError.failed(
                status: output.status, output: String(decoding: output.standardError.prefix(2_000), as: UTF8.self))
        }
    }
}
