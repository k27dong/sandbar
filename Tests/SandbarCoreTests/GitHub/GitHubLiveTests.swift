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
        #expect(PullRequestList(mine: lists.mine, reviewRequests: lists.reviewRequests).openCount == lists.mine.count)
    }
}
