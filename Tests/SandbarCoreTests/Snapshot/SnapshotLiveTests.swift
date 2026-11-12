import Foundation
import SandbarCore
import Testing

@Suite(.enabled(if: Live.isOn), .serialized)
struct SnapshotLiveTests {
    struct Found: Decodable {
        var number: Int
    }

    static let networkIsCut = ProcessInfo.processInfo.environment["SANDBAR_NETWORK"] == "none"
    static let savedCopy = URL(filePath: #filePath).appending(path: "../../../../.build/sandbar-live-snapshot.json")
        .standardized
    static let ownSignIns = [
        Account(tool: .codex, name: "Personal", plan: "", profile: nil),
        Account(tool: .claude, name: "Work", plan: "", profile: nil),
    ]

    let gh = Live.program("SANDBAR_LIVE_GH")
    let tools: [Tool: URL] = [.claude: Live.program("SANDBAR_LIVE_CLAUDE"), .codex: Live.program("SANDBAR_LIVE_CODEX")]

    var github: GitHubClient {
        GitHubClient(token: { [gh] in try await GitHubSignIn.ghToken(gh: gh) })
    }

    func print(_ snapshot: Snapshot) {
        let lists = snapshot.pullRequests
        Swift.print(
            "pull requests: mine \(lists.value.mine.count), review requests \(lists.value.reviewRequests.count),",
            "trouble \(lists.trouble?.rawValue ?? "none")")
        for entry in snapshot.accounts {
            Swift.print("account \(entry.account.tool): trouble \(entry.limits.trouble?.rawValue ?? "none")")
            for limit in entry.limits.value { Swift.print("usage row: \(limit.label) \(limit.amount)") }
        }
    }

    @Test(.enabled(if: !networkIsCut)) func theOwnSignInsReadEverythingAndAnEmptyProfileIsSignedOut() async throws {
        let snapshot = await Snapshot.empty.refreshed(
            .all, github: github, accounts: Self.ownSignIns, tools: tools, now: .now)
        print(snapshot)
        let search = try await Command.run(
            gh, ["search", "prs", "--author=@me", "--state=open", "--json", "number", "--limit", "1000"])
        try #require(search.status == 0)
        let found = try JSONDecoder().decode([Found].self, from: search.standardOutput)
        #expect(snapshot.pullRequests.trouble == nil)
        #expect(snapshot.pullRequests.value.mine.count == found.count)
        #expect(snapshot.accounts.map(\.account.tool) == [.claude, .codex])
        #expect(snapshot.accounts.map(\.limits.trouble) == [nil, nil])
        #expect(snapshot.accounts.flatMap(\.limits.value).count == 3)
        try SavedSnapshot.write(snapshot, to: Self.savedCopy)

        let profiles = FileManager.default.temporaryDirectory.appending(path: "sandbar-\(UUID().uuidString)")
        let emptyProfile = Account(
            tool: .claude, name: "Personal", plan: "", profile: try Account.makeProfile(in: profiles))
        let again = await snapshot.refreshed(
            .all, github: github, accounts: Self.ownSignIns + [emptyProfile], tools: tools, now: .now)
        print(again)
        #expect(again.pullRequests.trouble == nil)
        #expect(again.pullRequests.value.mine.count == found.count)
        #expect(again.accounts.map(\.account.id) == [Self.ownSignIns[1].id, emptyProfile.id, Self.ownSignIns[0].id])
        #expect(again.accounts.map(\.limits.trouble) == [nil, .signedOut, nil])
        var rows = snapshot.accounts.map(\.limits.value.count)
        rows.insert(0, at: 1)
        #expect(again.accounts.map(\.limits.value.count) == rows)
    }

    @Test(.enabled(if: networkIsCut)) func withoutANetworkThePullRequestsAreOfflineAndTheSavedCopyReadsWhole()
        async throws
    {
        let saved = SavedSnapshot.read(from: Self.savedCopy)
        #expect(saved.pullRequests.readAt != nil)
        #expect(saved.accounts.flatMap(\.limits.value).count == 3)
        let snapshot = await saved.refreshed(
            .all, github: github, accounts: saved.accounts.map(\.account), tools: tools, now: .now)
        print(snapshot)
        #expect(snapshot.pullRequests.trouble == .offline)
        #expect(snapshot.pullRequests.value == saved.pullRequests.value)
        #expect(snapshot.pullRequests.readAt == saved.pullRequests.readAt)
        for (now, before) in zip(snapshot.accounts, saved.accounts) where now.limits.trouble != nil {
            #expect(now.limits.value == before.limits.value)
        }
        try FileManager.default.removeItem(at: Self.savedCopy)  // it holds real pull requests
    }
}
