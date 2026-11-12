import Foundation

package enum CodexUsage {
    private static let signedOutCode: Int32 = -32600

    package static func limits(
        tool: URL, environment: [String: String], timeout: Duration = .seconds(30)
    ) async throws -> [UsageLimit] {
        let server = try await CodexServer(tool: tool, environment: environment, timeout: timeout)
        let answer: Answer
        do {
            answer = try await server.ask("account/rateLimits/read", [String: String]())
        } catch {
            await server.stop()
            if case ToolError.failed(signedOutCode, let message) = error, message.contains("authentication required") {
                throw ToolError.signedOut
            }
            throw error
        }
        await server.stop()
        return limits(in: answer)
    }

    package static func limits(inAnswer answer: Data) throws -> [UsageLimit] {
        do {
            return limits(in: try JSONDecoder().decode(Answer.self, from: answer))
        } catch is DecodingError {
            throw ToolError.notUnderstood(String(decoding: answer.suffix(2_000), as: UTF8.self))
        }
    }

    private static func limits(in answer: Answer) -> [UsageLimit] {
        [answer.rateLimits.primary, answer.rateLimits.secondary].compactMap { $0 }.map { window in
            UsageLimit(
                window: window.windowDurationMins == 300
                    ? .fiveHours
                    : window.windowDurationMins == 10_080 ? .week : .other("\(window.windowDurationMins / 60)h"),
                used: window.usedPercent / 100,
                resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) })
        }
    }

    private struct Answer: Decodable, Sendable {
        struct Windows: Decodable, Sendable {
            var primary: Window?
            var secondary: Window?
        }
        struct Window: Decodable, Sendable {
            var usedPercent: Double
            var windowDurationMins: Int
            var resetsAt: TimeInterval?
        }
        var rateLimits: Windows
    }
}
