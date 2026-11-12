package struct PullRequestList: Equatable, Sendable {
    package enum Entry: Equatable, Identifiable, Sendable {
        case single(PullRequest)
        case stack(Stack)

        package var id: String {
            switch self {
            case .single(let pullRequest): pullRequest.id
            case .stack(let stack): stack.id
            }
        }

        package var lead: PullRequest {
            switch self {
            case .single(let pullRequest): pullRequest
            case .stack(let stack): stack.pullRequests[0]
            }
        }
    }

    package var reviewRequests: [PullRequest]
    package var mine: [Entry]
    package var openCount: Int

    package init(mine: [PullRequest], reviewRequests: [PullRequest]) {
        let grouped = Stack.grouping(mine)
        let entries = grouped.stacks.map(Entry.stack) + grouped.singles.map(Entry.single)
        self.mine = entries.sorted { ($0.lead.place, $0.lead.createdAt) < ($1.lead.place, $1.lead.createdAt) }
        self.reviewRequests = reviewRequests.sorted { $0.createdAt < $1.createdAt }
        openCount = mine.count
    }
}

extension PullRequest {
    package var place: Int {
        let checksStep =
            switch checks.verdict {
            case .passed, nil: 0
            case .running: 1
            case .failed: 2
            }
        return switch state {
        case .merging: 1
        case .approved: 2 + checksStep
        case .open: 5 + checksStep
        case .changesRequested: 8
        case .draft: 9
        }
    }
}
