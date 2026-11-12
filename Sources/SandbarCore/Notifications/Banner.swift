import Foundation

package struct NotificationSettings: Codable, Equatable, Sendable {
    package var approved = true
    package var changesRequested = true
    package var checksFailed = true
    package var limitReset = true
    package var reviewRequested = false
    package var limitNear = false

    package init() {}
}

package struct Banner: Equatable, Identifiable, Sendable {
    package enum Opens: Equatable, Sendable {
        case pullRequest(URL)
        case panel
    }

    package var id: String
    package var title: String
    package var body: String
    package var opens: Opens
    package var deliverAt: Date?

    package static func now(for changes: [Change], settings: NotificationSettings, at now: Date) -> [Banner] {
        var approved: [(pullRequest: PullRequest, by: String?)] = []
        var changesRequested: [(pullRequest: PullRequest, by: String?)] = []
        var checksFailed: [PullRequest] = []
        var reviewRequested: [PullRequest] = []
        var resets: [(account: Account, labels: [String])] = []
        var near: [(account: Account, limit: UsageLimit)] = []
        for change in changes {
            switch change {
            case .approved(let pullRequest, let by): approved.append((pullRequest, by))
            case .changesRequested(let pullRequest, let by): changesRequested.append((pullRequest, by))
            case .checksFailed(let pullRequest): checksFailed.append(pullRequest)
            case .reviewRequested(let pullRequest): reviewRequested.append(pullRequest)
            case .limitReset(let account, let limit):
                if let index = resets.firstIndex(where: { $0.account.id == account.id }) {
                    resets[index].labels.append(limit.label)
                } else {
                    resets.append((account, [limit.label]))
                }
            case .limitNear(let account, let limit): near.append((account, limit))
            }
        }

        let seconds = Int(now.timeIntervalSince1970)
        var banners: [Banner] = []
        if settings.approved, !approved.isEmpty {
            banners.append(
                pullRequestBanner(
                    "approved-\(seconds)", title: headline("Approved", by: approved.map(\.by)),
                    pullRequests: approved.map(\.pullRequest)))
        }
        if settings.changesRequested, !changesRequested.isEmpty {
            banners.append(
                pullRequestBanner(
                    "changesRequested-\(seconds)",
                    title: headline("Changes requested", by: changesRequested.map(\.by)),
                    pullRequests: changesRequested.map(\.pullRequest)))
        }
        if settings.checksFailed, let first = checksFailed.first {
            let failed = first.checks.failed
            let title =
                switch (checksFailed.count, failed.count) {
                case (1, 1): "\(failed[0]) failed"
                case (1, 2...): "\(failed.count) checks failed"
                default: "Checks failed"
                }
            banners.append(pullRequestBanner("checksFailed-\(seconds)", title: title, pullRequests: checksFailed))
        }
        if settings.reviewRequested, !reviewRequested.isEmpty {
            banners.append(
                pullRequestBanner(
                    "reviewRequested-\(seconds)",
                    title: headline("Review requested", by: reviewRequested.map(\.author.login)),
                    pullRequests: reviewRequested))
        }
        if settings.limitReset {
            banners += resets.map {
                limitResetBanner(
                    "limit-reset-\($0.account.id.uuidString)-\(seconds)", account: $0.account.name, labels: $0.labels,
                    deliverAt: nil)
            }
        }
        if settings.limitNear {
            banners += near.map { account, limit in
                let left = limit.end(now: now).map { " · \(ShortTime.left(until: $0, from: now)) left" } ?? ""
                return Banner(
                    id: "limit-near-\(account.id.uuidString)-\(limit.label)-\(seconds)",
                    title: "\(Int((limit.used * 100).rounded()))% used",
                    body: "\(account.name) · \(limit.label)\(left)", opens: .panel, deliverAt: nil)
            }
        }
        return banners
    }

    package static func resets(in snapshot: Snapshot, settings: NotificationSettings, now: Date) -> [Banner] {
        guard settings.limitReset else { return [] }
        return snapshot.accounts.flatMap { entry in
            let upcoming = entry.limits.value.compactMap { limit in
                limit.resetsAt.flatMap { $0 > now ? (at: $0, label: limit.label) : nil }
            }
            return Dictionary(grouping: upcoming) { Int(($0.at.timeIntervalSince1970 / 60).rounded(.down)) }
                .sorted { $0.key < $1.key }
                .map { minute, limits in
                    limitResetBanner(
                        "reset-\(entry.account.id.uuidString)-\(minute)", account: entry.account.name,
                        labels: limits.map(\.label), deliverAt: limits.map(\.at).min())
                }
        }
    }

    private static func headline(_ what: String, by people: [String?]) -> String {
        guard let first = people.first, let name = first, people.allSatisfy({ $0 == name }) else { return what }
        return "\(what) by \(name)"
    }

    private static func pullRequestBanner(_ id: String, title: String, pullRequests: [PullRequest]) -> Banner {
        let first = pullRequests[0]
        let more = pullRequests.count - 1
        return Banner(
            id: id, title: title, body: more == 0 ? first.title : "\(first.title) and \(more) more",
            opens: more == 0 ? .pullRequest(first.url) : .panel, deliverAt: nil)
    }

    private static func limitResetBanner(_ id: String, account: String, labels: [String], deliverAt: Date?) -> Banner {
        Banner(
            id: id, title: "Limit reset", body: "\(account) · \(labels.joined(separator: ", "))", opens: .panel,
            deliverAt: deliverAt)
    }
}
