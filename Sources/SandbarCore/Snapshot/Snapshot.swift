import Foundation

package struct Snapshot: Codable, Equatable, Sendable {
    package struct Parts: OptionSet, Sendable {
        package let rawValue: Int

        package init(rawValue: Int) {
            self.rawValue = rawValue
        }

        package static let pullRequests = Parts(rawValue: 1 << 0)
        package static let limits = Parts(rawValue: 1 << 1)
        package static let all: Parts = [.pullRequests, .limits]
    }

    package enum Trouble: String, Codable, Sendable { case signedOut, offline, toolMissing, failed }

    package struct Reading<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
        package var value: Value
        package var readAt: Date?
        package var askedAt: Date?
        package var trouble: Trouble?
        package var detail: String?

        package init(
            value: Value, readAt: Date? = nil, askedAt: Date? = nil, trouble: Trouble? = nil, detail: String? = nil
        ) {
            self.value = value
            self.readAt = readAt
            self.askedAt = askedAt
            self.trouble = trouble
            self.detail = detail
        }

        fileprivate func asked(at now: Date, by tool: Tool?, read: () async throws -> Value) async -> Reading {
            var reading = self
            reading.askedAt = now
            do {
                reading.value = try await read()
                reading.readAt = now
                reading.trouble = nil
                reading.detail = nil
            } catch {
                reading.trouble =
                    switch error {
                    case GitHubError.signedOut, ToolError.signedOut: .signedOut
                    case GitHubError.offline: .offline
                    case ToolError.missing: .toolMissing
                    default: .failed
                    }
                reading.detail = Snapshot.detail(of: error, tool: tool)
            }
            return reading
        }
    }

    package struct AccountLimits: Codable, Equatable, Identifiable, Sendable {
        package var account: Account
        package var limits: Reading<[UsageLimit]>

        package init(account: Account, limits: Reading<[UsageLimit]>) {
            self.account = account
            self.limits = limits
        }

        package var id: UUID { account.id }
    }

    package var pullRequests: Reading<PullRequestLists>
    package var accounts: [AccountLimits]

    package static let empty = Snapshot(
        pullRequests: Reading(value: PullRequestLists(mine: [], reviewRequests: [], hiddenOrganizations: [])),
        accounts: [])

    package func refreshed(
        _ parts: Parts, github: GitHubClient?, accounts: [Account], tools: [Tool: URL], now: Date,
        toolTimeout: Duration = .seconds(30)
    ) async -> Snapshot {
        async let pullRequests =
            parts.contains(.pullRequests)
            ? self.pullRequests.asked(at: now, by: nil) {
                guard let github else { throw GitHubError.signedOut }
                return try await github.pullRequests()
            }
            : self.pullRequests

        let known = Dictionary(self.accounts.map { ($0.id, $0.limits) }) { first, _ in first }
        let ordered = Tool.allCases.flatMap { tool in accounts.filter { $0.tool == tool } }
        let accountLimits = await withTaskGroup(of: (Int, AccountLimits).self) { group in
            for (index, account) in ordered.enumerated() {
                let last = known[account.id] ?? Reading(value: [])
                group.addTask {
                    guard parts.contains(.limits) else { return (index, AccountLimits(account: account, limits: last)) }
                    let limits = await last.asked(at: now, by: account.tool) {
                        guard let program = tools[account.tool] else { throw ToolError.missing }
                        let (status, limits) =
                            switch account.tool {
                            case .claude: (ClaudeSignIn.status, ClaudeUsage.limits)
                            case .codex: (CodexSignIn.status, CodexUsage.limits)
                            }
                        guard try await status(program, account.environment, toolTimeout).isSignedIn else {
                            throw ToolError.signedOut  // a signed-out limits read gives no report and no error
                        }
                        return try await limits(program, account.environment, toolTimeout)
                    }
                    return (index, AccountLimits(account: account, limits: limits))
                }
            }
            return await group.reduce(into: []) { $0.append($1) }.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return Snapshot(pullRequests: await pullRequests, accounts: accountLimits)
    }

    package static func detail(of error: any Error, tool: Tool?) -> String {
        let name = tool?.programName
        let sentence =
            switch error {
            case GitHubError.signedOut: "GitHub sign-in is missing or no longer valid."
            case GitHubError.offline: "GitHub could not be reached."
            case GitHubError.rejected(let status, _): "GitHub answered with status \(status)."
            case GitHubError.notUnderstood: "GitHub's answer was not understood."
            case let error as ToolError:
                if let name {
                    switch error {
                    case .missing: "\(name) was not found."
                    case .signedOut: "Signed out."
                    case .timedOut: "\(name) did not answer in time."
                    case .failed(let status, let output):
                        output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "\(name) ended with status \(status)."
                            : output.trimmingCharacters(in: .whitespacesAndNewlines)
                    case .notUnderstood: "\(name)'s answer was not understood."
                    }
                } else {
                    "The read failed."
                }
            case is DownloadError: name.map { "\($0) could not be fetched." } ?? "The read failed."
            default: "The read failed."
            }
        return String(sentence.prefix(300))
    }

    package func due(at now: Date) -> Parts {
        let lists = pullRequests.value
        let checksRunning = (lists.mine + lists.reviewRequests).contains { $0.checks.verdict == .running }
        let pullRequestPace: TimeInterval = checksRunning ? 20 : 60
        let limitsPace: TimeInterval = 300
        var due: Parts = []
        if pullRequests.askedAt.map({ now.timeIntervalSince($0) >= pullRequestPace }) ?? true {
            due.insert(.pullRequests)
        }
        if accounts.contains(where: { $0.limits.askedAt.map { now.timeIntervalSince($0) >= limitsPace } ?? true }) {
            due.insert(.limits)
        }
        return due
    }

    package func status(at now: Date, isRefreshing: Bool, isOffline: Bool) -> String {
        if isRefreshing { return "Updating…" }
        let offline = isOffline ? "Offline." : nil
        guard let readAt = pullRequests.readAt else { return offline ?? "" }
        let age = now.timeIntervalSince(readAt) < 60 ? "just now" : "\(ShortTime.age(since: readAt, to: now)) ago"
        return [offline, "Updated \(age)"].compactMap(\.self).joined(separator: " ")
    }

    package var fullestLimit: UsageLimit? {
        accounts.flatMap(\.limits.value).max { $0.used < $1.used }
    }
}
