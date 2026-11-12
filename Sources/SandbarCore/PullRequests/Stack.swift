package struct Stack: Hashable, Identifiable, Sendable {
    package var pullRequests: [PullRequest]
    package var id: String

    package func shown(isOpen: Bool) -> [PullRequest] {
        isOpen || pullRequests.count <= 3 ? pullRequests : Array(pullRequests.prefix(2))
    }

    package static func grouping(_ pullRequests: [PullRequest]) -> (stacks: [Stack], singles: [PullRequest]) {
        let stacked =
            pullRequests
            .compactMap { pullRequest in pullRequest.stack.map { (place: $0, pullRequest: pullRequest) } }
            .sorted { $0.place.position < $1.place.position }
        var githubGroups: [[PullRequest]] = []
        var groupIndex: [String: Int] = [:]
        for (place, pullRequest) in stacked {
            let key = "\(pullRequest.repository)#\(place.number)"
            if let index = groupIndex[key] {
                githubGroups[index].append(pullRequest)
            } else {
                groupIndex[key] = githubGroups.count
                githubGroups.append([pullRequest])
            }
        }
        let groups = githubGroups + chainedByBranch(pullRequests)

        var stacks: [Stack] = []
        var singles: [PullRequest] = []
        for group in groups {
            let bottom = group[0]
            guard group.count > 1 else {
                singles.append(bottom)
                continue
            }
            let name = bottom.stack.map { String($0.number) } ?? bottom.headBranch
            stacks.append(Stack(pullRequests: group, id: "\(bottom.repository)#\(name)"))
        }
        return (stacks, singles)
    }

    private struct Branch: Hashable {
        var repository: String
        var name: String
    }

    private static func chainedByBranch(_ pullRequests: [PullRequest]) -> [[PullRequest]] {
        let byHead = Dictionary(grouping: pullRequests) { Branch(repository: $0.repository, name: $0.headBranch) }
        let byBase = Dictionary(grouping: pullRequests) { Branch(repository: $0.repository, name: $0.baseBranch) }
        func link(at branch: Branch) -> (lower: PullRequest, upper: PullRequest)? {
            guard let lower = byHead[branch], lower.count == 1, let upper = byBase[branch], upper.count == 1,
                lower[0].stack == nil, upper[0].stack == nil
            else { return nil }
            return (lower[0], upper[0])
        }

        var chains: [[PullRequest]] = []
        var chained: Set<String> = []
        for start in pullRequests where start.stack == nil && !chained.contains(start.id) {
            var bottom = start
            var seen: Set<String> = [start.id]
            while let lower = link(at: Branch(repository: bottom.repository, name: bottom.baseBranch))?.lower,
                seen.insert(lower.id).inserted
            {
                bottom = lower
            }
            var chain = [bottom]
            chained.insert(bottom.id)
            var top = bottom
            while let upper = link(at: Branch(repository: top.repository, name: top.headBranch))?.upper,
                chained.insert(upper.id).inserted
            {
                chain.append(upper)
                top = upper
            }
            chains.append(chain)
        }
        return chains
    }
}
