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
        self.mine = entries.sorted {
            ($0.lead.place, $0.lead.createdAt, $0.lead.number) < ($1.lead.place, $1.lead.createdAt, $1.lead.number)
        }
        self.reviewRequests = reviewRequests.sorted { ($0.createdAt, $0.number) < ($1.createdAt, $1.number) }
        openCount = mine.count
    }
}

extension PullRequestList {
    package enum Selection: Hashable, Sendable {
        case pullRequest(PullRequest.ID)
        case fold(Stack.ID)
    }

    package enum Row: Sendable {
        case pullRequest(PullRequest)
        case fold(Stack)

        package var selection: Selection {
            switch self {
            case .pullRequest(let pullRequest): .pullRequest(pullRequest.id)
            case .fold(let stack): .fold(stack.id)
            }
        }
    }

    package static func rows(of stack: Stack, isOpen: Bool, topFirst: Bool) -> [Row] {
        let pullRequests = stack.shown(isOpen: isOpen).map(Row.pullRequest)
        let fold = stack.shown(isOpen: false).count < stack.pullRequests.count ? [Row.fold(stack)] : []
        return topFirst ? fold + pullRequests.reversed() : pullRequests + fold
    }

    package func rows(openStacks: Set<Stack.ID>, topFirst: Bool) -> [Row] {
        reviewRequests.map(Row.pullRequest)
            + mine.flatMap { entry in
                switch entry {
                case .single(let pullRequest): [Row.pullRequest(pullRequest)]
                case .stack(let stack): Self.rows(of: stack, isOpen: openStacks.contains(stack.id), topFirst: topFirst)
                }
            }
    }

    package static func selection(after selected: Selection?, movedBy step: Int, in rows: [Row]) -> Selection? {
        let selections = rows.map(\.selection)
        guard let index = selected.flatMap(selections.firstIndex(of:)) else {
            return step > 0 ? selections.first : selections.last
        }
        return selections[min(max(index + step, 0), selections.count - 1)]
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
