import Foundation

package enum Change: Equatable, Sendable {
    case approved(PullRequest, by: String?)
    case changesRequested(PullRequest, by: String?)
    case checksFailed(PullRequest)
    case reviewRequested(PullRequest)
    case limitReset(account: Account, limit: UsageLimit)
    case limitNear(account: Account, limit: UsageLimit)
}

extension Snapshot {
    package func changes(since old: Snapshot, in parts: Parts) -> [Change] {
        var changes: [Change] = []
        if parts.contains(.pullRequests), old.pullRequests.readAt != nil, pullRequests.readAt != nil {
            let before = old.pullRequests.value
            let lists = pullRequests.value
            let was = Dictionary((before.mine + before.reviewRequests).map { ($0.id, $0) }) { first, _ in first }
            for pullRequest in lists.mine {
                guard let last = was[pullRequest.id] else { continue }
                if pullRequest.verdict != last.verdict, let verdict = pullRequest.verdict {
                    let newest = pullRequest.reviews.filter { $0.verdict == verdict }.max {
                        $0.submittedAt < $1.submittedAt
                    }
                    switch verdict {
                    case .approved: changes.append(.approved(pullRequest, by: newest?.author))
                    case .changesRequested: changes.append(.changesRequested(pullRequest, by: newest?.author))
                    }
                }
                if pullRequest.checks.verdict == .failed, last.checks.verdict != .failed {
                    changes.append(.checksFailed(pullRequest))
                }
            }
            let asked = Set(before.reviewRequests.map(\.id))
            changes += lists.reviewRequests.filter { !asked.contains($0.id) }.map(Change.reviewRequested)
        }
        if parts.contains(.limits) {
            let before = Dictionary(old.accounts.map { ($0.id, $0) }) { first, _ in first }
            for account in accounts {
                guard let was = before[account.id], was.limits.readAt != nil, account.limits.readAt != nil else {
                    continue
                }
                for limit in account.limits.value {
                    guard
                        let last = was.limits.value.first(where: {
                            $0.window == limit.window && $0.model == limit.model
                        })
                    else { continue }
                    if last.used < 0.8, limit.used >= 0.8 {
                        changes.append(.limitNear(account: account.account, limit: limit))
                    }
                    if limit.resetsAt == nil, limit.used < last.used {
                        changes.append(.limitReset(account: account.account, limit: limit))
                    }
                }
            }
        }
        return changes
    }
}
