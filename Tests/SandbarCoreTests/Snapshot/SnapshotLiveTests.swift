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

    func printCounts(_ snapshot: Snapshot) {
        let lists = snapshot.pullRequests
        Swift.print(
            "pull requests: mine \(lists.value.mine.count), review requests \(lists.value.reviewRequests.count),",
            "trouble \(lists.trouble?.rawValue ?? "none")")
        for entry in snapshot.accounts {
            Swift.print(
                "account \(entry.account.tool): trouble \(entry.limits.trouble?.rawValue ?? "none"), rows",
                entry.limits.value.map(\.label))
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

    @Test(.enabled(if: !networkIsCut)) func aClaudeToolThatIsNotThereIsMissingAndCodexStillReads() async throws {
        var tools = tools
        tools[.claude] = folder.appending(path: "claude")
        let snapshot = await Snapshot.empty.refreshed(
            .limits, github: github, accounts: Self.ownSignIns, tools: tools, now: .now)
        printCounts(snapshot)
        let troubles = snapshot.accounts.map(\.limits.trouble)
        try #require(troubles == [.toolMissing, nil])
        let detail = snapshot.accounts[0].limits.detail
        #expect(detail == "Claude Code was not found.")
        let codexRows = snapshot.accounts[1].limits.value.count
        #expect(codexRows > 0)
        let pullRequestsUntouched = snapshot.pullRequests == Snapshot.empty.pullRequests
        #expect(pullRequestsUntouched)
    }

    @Test(.enabled(if: !networkIsCut)) func aWrongGitHubTokenIsSignedOutAndKeepsTheListsRead() async throws {
        let readAt = Date.now
        let first = await Snapshot.empty.refreshed(
            .pullRequests, github: github, accounts: [], tools: tools, now: readAt)
        printCounts(first)
        let firstTrouble = first.pullRequests.trouble
        try #require(firstTrouble == nil)

        let wrongToken = GitHubClient(token: { "not-a-real-token" })
        let askedAt = readAt + 60
        let second = await first.refreshed(.pullRequests, github: wrongToken, accounts: [], tools: tools, now: askedAt)
        printCounts(second)
        let secondTrouble = second.pullRequests.trouble
        #expect(secondTrouble == .signedOut)
        let listsKept = second.pullRequests.value == first.pullRequests.value
        #expect(listsKept)  // a comparison inside #expect would print real titles when it fails
        #expect(second.pullRequests.readAt == readAt)
        #expect(second.pullRequests.askedAt == askedAt)
    }

    @Test(.enabled(if: !networkIsCut)) func twoRefreshesInARowChangeNothingAndBannerNothing() async throws {
        let first = await Snapshot.empty.refreshed(
            .all, github: github, accounts: Self.ownSignIns, tools: tools, now: .now)
        printCounts(first)
        let second = await first.refreshed(.all, github: github, accounts: Self.ownSignIns, tools: tools, now: .now)
        printCounts(second)
        let troubles = [first, second].flatMap { [$0.pullRequests.trouble] + $0.accounts.map(\.limits.trouble) }
        try #require(troubles == [nil, nil, nil, nil, nil, nil])

        var everything = NotificationSettings()
        everything.reviewRequested = true
        everything.limitNear = true
        let now = Date.now
        let changes = second.changes(since: first, in: .all)
        let banners = Banner.now(for: changes, settings: everything, at: now)
        let resetsBefore = Banner.resets(in: first, settings: everything, now: now)
        let resetsAfter = Banner.resets(in: second, settings: everything, now: now)
        let differingResets =
            resetsAfter.filter { !resetsBefore.contains($0) }.count
            + resetsBefore.filter { !resetsAfter.contains($0) }.count
        Swift.print("changes \(changes.count), banners \(banners.count), differing reset banners \(differingResets)")
        let changeCount = changes.count  // fails honestly if a real pull request changes between the two reads
        #expect(changeCount == 0)
        let bannerCount = banners.count
        #expect(bannerCount == 0)
        #expect(differingResets == 0)
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
