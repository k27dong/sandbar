import Foundation
import SandbarCore
import Testing

struct GitHubLiveTests {
    struct Found: Decodable {
        var number: Int
    }

    @Test(.enabled(if: Live.isOn)) func readsTheSameOpenPullRequestsAsGh() async throws {
        let gh = Live.program("SANDBAR_LIVE_GH")
        let lists: PullRequestLists
        do {
            lists = try await GitHubClient(token: { try await GitHubSignIn.ghToken(gh: gh) }).pullRequests()
        } catch let error as GitHubError {
            let kind =
                switch error {
                case .signedOut: "signed out"
                case .offline: "offline"
                case .rejected(let status, _): "rejected with status \(status)"
                case .notUnderstood: "not understood"
                }
            Issue.record("the real read failed: \(kind)")  // the error itself may quote real pull requests
            return
        }
        for pullRequest in lists.mine {
            print(
                "place \(pullRequest.place) state \(pullRequest.state)",
                "checks \(pullRequest.checks.verdict.map(\.rawValue) ?? "none") #\(pullRequest.number)")
        }
        print("mine \(lists.mine.count), review requests \(lists.reviewRequests.count)")
        let reviewChecks = Dictionary(grouping: lists.reviewRequests) { $0.checks.verdict.map(\.rawValue) ?? "none" }
        print("review request checks", reviewChecks.mapValues(\.count).sorted { $0.key < $1.key })
        print("hidden organizations \(lists.hiddenOrganizations.count)")

        let search = try await Command.run(
            gh, ["search", "prs", "--author=@me", "--state=open", "--json", "number", "--limit", "1000"])
        try #require(search.status == 0)
        let found = try JSONDecoder().decode([Found].self, from: search.standardOutput)
        #expect(lists.mine.count == found.count)
        #expect(lists.mine.allSatisfy { (1...9).contains($0.place) })
        let list = PullRequestList(mine: lists.mine, reviewRequests: lists.reviewRequests)
        #expect(list.openCount == lists.mine.count)

        let stacks = list.mine.compactMap { entry in
            if case .stack(let stack) = entry { stack } else { nil }
        }
        for stack in stacks {
            let members = stack.pullRequests
            let folded = stack.shown(isOpen: false)
            let foldedRows = folded.count + (members.count > 3 ? 1 : 0)
            let positions = members.compactMap(\.stack?.position)
            let reportedByGitHub = positions.count == members.count
            print(
                "stack \(reportedByGitHub ? "by GitHub" : "by branches"): \(members.count) members, bottom first",
                members.map { "#\($0.number)" }.joined(separator: " "), "folded rows \(foldedRows)")
            let bottomFirst =
                reportedByGitHub
                ? zip(positions, positions.dropFirst()).allSatisfy(<)
                : zip(members, members.dropFirst()).allSatisfy { $0.headBranch == $1.baseBranch }
            #expect(bottomFirst)
            let foldsAsPromised = members.count <= 3 ? folded == members : folded == Array(members.prefix(2))
            #expect(foldsAsPromised)  // a comparison inside #expect would print real titles when it fails
        }
        let stacked = stacks.flatMap(\.pullRequests).map(\.id)
        let distinct = Set(stacked).count
        #expect(distinct == stacked.count)
        print("stacks \(stacks.count)")
    }
}
