import Foundation
import SandbarCore
import Testing

@Suite(.enabled(if: Live.isOn), .serialized)
struct SnapshotLiveTests {
    struct Found: Decodable {
        var number: Int
    }

    static let networkIsCut = ProcessInfo.processInfo.environment["SANDBAR_NETWORK"] == "none"
    static let ownSignIns = [
        Account(tool: .codex, name: "Personal", plan: "", profile: nil),
        Account(tool: .claude, name: "Work", plan: "", profile: nil),
    ]

    let gh = Live.program("SANDBAR_LIVE_GH")
    let tools: [Tool: URL] = [.claude: Live.program("SANDBAR_LIVE_CLAUDE"), .codex: Live.program("SANDBAR_LIVE_CODEX")]
    let folder = FileManager.default.temporaryDirectory.appending(path: "sandbar-\(UUID().uuidString)")

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

    func removeFolder() {
        #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) }
    }

    @Test(.enabled(if: !networkIsCut)) func theOwnSignInsReadEverythingAndAnEmptyProfileIsSignedOut() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { removeFolder() }  // the saved copy holds real pull requests
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

        let file = folder.appending(path: "snapshot.json")
        try SavedSnapshot.write(snapshot, to: file)
        let saved = SavedSnapshot.read(from: file)
        #expect(saved.pullRequests.value.mine.map(\.id) == snapshot.pullRequests.value.mine.map(\.id))
        #expect(
            saved.accounts.flatMap(\.limits.value).map(\.label)
                == snapshot.accounts.flatMap(\.limits.value).map(\.label))

        let emptyProfile = Account(
            tool: .claude, name: "Personal", plan: "",
            profile: try Account.makeProfile(in: folder.appending(path: "Profiles")))
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
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { removeFolder() }
        var madeUp = SavedSnapshotTests.snapshot
        madeUp.pullRequests.trouble = nil
        madeUp.pullRequests.detail = nil
        let file = folder.appending(path: "snapshot.json")
        try SavedSnapshot.write(madeUp, to: file)

        let snapshot = await SavedSnapshot.read(from: file).refreshed(
            .pullRequests, github: github, accounts: madeUp.accounts.map(\.account), tools: tools,
            now: Sample.now + 60)
        print(snapshot)
        #expect(snapshot.pullRequests.trouble == .offline)
        #expect(snapshot.pullRequests.value == madeUp.pullRequests.value)
        #expect(snapshot.pullRequests.readAt == madeUp.pullRequests.readAt)
        #expect(snapshot.pullRequests.askedAt == Sample.now + 60)
        #expect(snapshot.accounts == madeUp.accounts)
        #expect(SavedSnapshot.read(from: file) == madeUp)
    }
}
