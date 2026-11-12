import Foundation

package enum ClaudeUsage {
    private static let arguments = [
        "--safe-mode", "--no-session-persistence", "-p", "/usage", "--output-format", "stream-json", "--verbose",
    ]
    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    package static func limits(
        tool: URL, environment: [String: String], timeout: Duration = .seconds(30)
    ) async throws -> [UsageLimit] {
        let output = try await Command.run(tool, arguments, environment: environment, timeout: timeout)
        if let limits = try reported(in: output.standardOutput) { return limits }
        guard output.status != 0 else { throw ToolError.notUnderstood(tail(output.standardOutput)) }
        let complaint = output.standardError.isEmpty ? output.standardOutput : output.standardError
        throw ToolError.failed(status: output.status, output: tail(complaint))
    }

    package static func limits(inReport output: Data) throws -> [UsageLimit] {
        guard let limits = try reported(in: output) else { throw ToolError.notUnderstood(tail(output)) }
        return limits
    }

    private static func tail(_ data: Data) -> String {
        String(decoding: data.suffix(2_000), as: UTF8.self)
    }

    private static func reported(in output: Data) throws -> [UsageLimit]? {
        let printed = tail(output)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let report: RateLimits
        do {
            let objects = output.split(separator: 0x0A).filter {
                (try? JSONSerialization.jsonObject(with: Data($0))) is [String: Any]
            }
            let found = try objects.compactMap { try decoder.decode(Line.self, from: Data($0)).usageReport }.first
            guard let found else { return nil }
            report = found.rateLimits
        } catch is DecodingError {
            throw ToolError.notUnderstood(printed)
        }
        var limits = try report.limits.map { limit in
            UsageLimit(
                window: window(group: limit.group), model: limit.scope?.model?.displayName, used: limit.percent / 100,
                resetsAt: try limit.resetsAt.map { text in
                    do { return try Date(text, strategy: timestamp) } catch { throw ToolError.notUnderstood(printed) }
                })
        }
        let extra = report.extraUsage
        if extra.isEnabled, let budget = extra.monthlyLimit, budget > 0 {
            guard let spent = extra.usedCredits else { throw ToolError.notUnderstood(printed) }
            limits.append(UsageLimit(window: .month, used: spent / budget, dollars: Int((spent / 100).rounded(.down))))
        }
        return limits
    }

    private static func window(group: String) -> UsageLimit.Window {
        switch group {
        case "weekly": .week
        case "five_hour", "session": .fiveHours
        default: .other(group)
        }
    }

    private struct Line: Decodable {
        var usageReport: Report?
    }

    private struct Report: Decodable {
        var rateLimits: RateLimits
    }

    private struct RateLimits: Decodable {
        var limits: [Limit]
        var extraUsage: ExtraUsage
    }

    private struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable {
                var displayName: String
            }
            var model: Model?
        }
        var group: String
        var percent: Double
        var resetsAt: String?
        var scope: Scope?
    }

    private struct ExtraUsage: Decodable {
        var isEnabled: Bool
        var monthlyLimit: Double?
        var usedCredits: Double?
    }
}
