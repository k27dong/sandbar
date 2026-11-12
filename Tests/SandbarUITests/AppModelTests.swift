import AppKit
import SandbarCore
import SandbarUI
import Testing

func withDefaults(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
    let suite = "sandbar-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try await body(defaults)
}

@Suite(.serialized) struct AppModelTests {
    static let now = Date(timeIntervalSince1970: 1_794_506_400)  // 2026-11-12 18:00 UTC

    nonisolated static let statuses: [(readSecondsAgo: TimeInterval?, trouble: Snapshot.Trouble?, status: String)] = [
        (59, nil, "Updated just now"), (60, nil, "Updated 1m ago"), (840, nil, "Updated 14m ago"),
        (840, .offline, "Offline. Updated 14m ago"), (840, .failed, "Offline. Updated 14m ago"),
        (840, .signedOut, "Updated 14m ago"), (nil, nil, ""), (nil, .signedOut, ""), (nil, .offline, "Offline."),
    ]

    private actor GitHub {
        static let answer = """
            {"data": {
              "mine": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": [
                {"id": "PR_41250", "number": 41250, "title": "Read saved carts through one cart reader",
                 "url": "https://github.com/acme/storefront/pull/41250", "isDraft": false,
                 "createdAt": "2026-11-09T18:00:00Z", "updatedAt": "2026-11-12T16:00:00Z",
                 "author": {"login": "kd", "avatarUrl": "https://example.com/faces/kd.png"},
                 "repository": {"nameWithOwner": "acme/storefront"},
                 "baseRefName": "main", "headRefName": "cart-reader", "reviewDecision": "APPROVED",
                 "latestOpinionatedReviews": {"nodes": []}, "isInMergeQueue": false, "stack": null,
                 "stackEntry": null,
                 "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}]}}]},
              "reviewRequests": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": []}}}
            """

        private(set) var requests = 0
        private var held: CheckedContinuation<Void, Never>?
        private var holdsNext = false

        nonisolated var client: GitHubClient {
            GitHubClient(token: { "made-up-token" }, send: { request in try await self.answer(request) })
        }

        func holdNext() {
            holdsNext = true
        }

        func release() {
            held?.resume()
            held = nil
        }

        private func answer(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests += 1
            if holdsNext {
                holdsNext = false
                await withCheckedContinuation { held = $0 }
            }
            let address = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(url: address, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(Self.answer.utf8), response)
        }
    }

    private func withStub(
        _ body: @MainActor (GitHub, AppModel.Files, UserDefaults) async throws -> Void
    ) async throws {
        try await withDefaults { defaults in
            let folder = FileManager.default.temporaryDirectory.appending(path: "sandbar-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
            try await body(GitHub(), AppModel.Files(folder: folder), defaults)
        }
    }

    private func withModel(
        _ body: @MainActor (AppModel, GitHub, AppModel.Files) async throws -> Void
    ) async throws {
        try await withStub { github, files, defaults in
            let model = AppModel(
                preferences: Preferences(defaults: defaults), now: Self.now, github: github.client, files: files)
            try await body(model, github, files)
        }
    }

    private func settled(_ model: AppModel) async {
        for _ in 0..<3 { await Task.yield() }
        while model.isRefreshing { await Task.yield() }
    }

    private func started(_ model: AppModel, _ github: GitHub) async {
        model.start()
        while await github.requests == 0 || model.isRefreshing { await Task.yield() }
    }

    @Test func everySettingStartsAtItsDefault() async throws {
        try await withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            #expect(preferences.titles == .oneLine)
            #expect(preferences.time == .sinceOpened)
            #expect(!preferences.showsRepository)
            #expect(preferences.stackOrder == .topFirst)
            #expect(!preferences.showsPace)
            #expect(preferences.chosenRepositories == nil)
            #expect(preferences.notifications.approved)
            #expect(preferences.notifications.changesRequested)
            #expect(preferences.notifications.checksFailed)
            #expect(preferences.notifications.limitReset)
            #expect(!preferences.notifications.reviewRequested)
            #expect(!preferences.notifications.limitNear)
            #expect(!preferences.notificationsPaused)
        }
    }

    @Test func aChangedSettingSurvivesANewPreferences() async throws {
        try await withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            preferences.titles = .twoLines
            preferences.time = .sinceUpdate
            preferences.showsRepository = true
            preferences.stackOrder = .bottomFirst
            preferences.showsPace = true
            preferences.chosenRepositories = ["acme/storefront", "acme/api"]
            preferences.notifications.approved = false
            preferences.notifications.changesRequested = false
            preferences.notifications.checksFailed = false
            preferences.notifications.limitReset = false
            preferences.notifications.reviewRequested = true
            preferences.notifications.limitNear = true
            preferences.notificationsPaused = true

            let again = Preferences(defaults: defaults)
            #expect(again.titles == .twoLines)
            #expect(again.time == .sinceUpdate)
            #expect(again.showsRepository)
            #expect(again.stackOrder == .bottomFirst)
            #expect(again.showsPace)
            #expect(again.chosenRepositories == ["acme/storefront", "acme/api"])
            #expect(again.notifications == preferences.notifications)
            #expect(!again.notifications.approved)
            #expect(again.notifications.limitNear)
            #expect(again.notificationsPaused)

            again.chosenRepositories = nil
            again.time = .off
            #expect(Preferences(defaults: defaults).chosenRepositories == nil)
            #expect(Preferences(defaults: defaults).time == .off)
        }
    }

    @Test func theListDropsARepositoryThatIsNotChosen() async throws {
        try await withDefaults { defaults in
            let model = AppModel(snapshot: stage("day"), preferences: Preferences(defaults: defaults), now: Self.now)
            #expect(model.list.openCount == 7)
            #expect(model.list.reviewRequests.map(\.number) == [6821, 6816])

            model.preferences.chosenRepositories = ["acme/storefront", "acme/tools"]
            #expect(model.list.openCount == 6)
            #expect(model.list.mine.allSatisfy { $0.lead.repository != "acme/api" })
            #expect(model.list.reviewRequests.isEmpty)
        }
    }

    @Test func aRefreshWritesTheSavedCopy() async throws {
        try await withModel { model, github, files in
            await model.refresh(.all)
            #expect(await github.requests == 1)
            #expect(model.list.mine.map(\.lead.number) == [41250])
            #expect(model.snapshot.pullRequests.readAt == Self.now)
            #expect(!model.isRefreshing)
            #expect(SavedSnapshot.read(from: files.snapshot) == model.snapshot)
        }
    }

    @Test func aSecondRefreshWhileTheFirstWaitsMakesNoRequest() async throws {
        try await withModel { model, github, _ in
            await github.holdNext()
            let first = Task { await model.refresh(.all) }
            while await github.requests == 0 { await Task.yield() }
            #expect(model.isRefreshing)
            #expect(model.status == "Updating…")

            await model.refresh(.all)
            #expect(await github.requests == 1)

            await github.release()
            await first.value
            #expect(await github.requests == 1)
            #expect(model.status == "Updated just now")
        }
    }

    @Test func openingThePanelRefreshesUnlessTheLastAskIsUnder15SecondsOld() async throws {
        try await withModel { model, github, _ in
            await model.refresh(.all)
            #expect(await github.requests == 1)

            model.now = Self.now + 10
            model.panelOpened()
            await settled(model)
            #expect(await github.requests == 1)

            model.now = Self.now + 16
            model.panelOpened()
            await settled(model)
            #expect(await github.requests == 2)
            #expect(model.snapshot.pullRequests.askedAt == Self.now + 16)
        }
    }

    @Test func withoutANetworkTheFooterSaysOfflineAndTheNumberDims() async throws {
        try await withModel { model, _, _ in
            await model.refresh(.all)
            model.now = Self.now + 840
            #expect(model.status == "Updated 14m ago")
            #expect(!model.isOffline)

            model.hasNetwork = false
            #expect(model.snapshot.pullRequests.trouble == nil)
            #expect(model.status == "Offline. Updated 14m ago")
            #expect(model.isOffline)
        }
    }

    @Test func nothingRefreshesWithoutANetwork() async throws {
        try await withModel { model, github, _ in
            await model.refresh(.all)
            model.hasNetwork = false

            model.now += 100
            await model.refreshWhatIsDue()
            #expect(await github.requests == 1, "the timer's turn")

            model.now += 100
            model.panelOpened()
            await settled(model)
            #expect(await github.requests == 1, "opening the panel")

            await model.refresh(.all)
            #expect(await github.requests == 1, "the footer's button")
        }
    }

    @Test func theNetworkComingBackRefreshesAtOnce() async throws {
        try await withModel { model, github, _ in
            await model.refresh(.all)
            model.hasNetwork = false
            model.now = Self.now + 840
            await settled(model)
            #expect(await github.requests == 1)

            model.hasNetwork = true
            await settled(model)
            #expect(await github.requests == 2)
            #expect(model.snapshot.pullRequests.readAt == Self.now + 840)
        }
    }

    @Test func nothingRefreshesBetweenSleepAndWake() async throws {
        try await withModel { model, github, _ in
            await started(model, github)
            try #require(model.hasNetwork)
            let workspace = NSWorkspace.shared

            workspace.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: workspace)
            await settled(model)
            model.now += 61
            await model.refreshWhatIsDue()
            let whileAsleep = await github.requests
            #expect(whileAsleep == 1)

            workspace.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: workspace)
            await settled(model)
            #expect(await github.requests == whileAsleep + 1)
        }
    }

    @Test func aReleasedModelNoLongerHearsTheWake() async throws {
        try await withStub { github, files, defaults in
            weak var released: AppModel?
            do {
                let model = AppModel(
                    preferences: Preferences(defaults: defaults), now: Self.now, github: github.client, files: files)
                await started(model, github)
                released = model
            }
            #expect(released == nil)

            let workspace = NSWorkspace.shared
            workspace.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: workspace)
            try await Task.sleep(for: .milliseconds(100))
            #expect(await github.requests == 1)
        }
    }

    @Test func aSecondStartDoesNothing() async throws {
        try await withModel { model, github, _ in
            await started(model, github)
            model.start()
            await settled(model)
            #expect(await github.requests == 1)
        }
    }

    @Test func accountsLoadFromTheFileAndReachEveryRefresh() async throws {
        try await withStub { github, files, defaults in
            let accounts = [
                Account(tool: .codex, name: "Personal", plan: "Plus", profile: nil),
                Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil),
            ]
            try Account.save(accounts, to: files.accounts)
            let model = AppModel(
                preferences: Preferences(defaults: defaults), now: Self.now, github: github.client, files: files,
                findTool: { _ in nil })
            #expect(model.accounts.isEmpty)

            await started(model, github)
            #expect(model.accounts == accounts)
            #expect(model.snapshot.accounts.map(\.account) == [accounts[1], accounts[0]])
            #expect(model.snapshot.accounts.allSatisfy { $0.limits.askedAt == Self.now })
        }
    }

    @Test func aToolFoundNowhereReachesTheSnapshotAsMissing() async throws {
        try await withStub { github, files, defaults in
            try Account.save(
                [Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil)], to: files.accounts)
            let model = AppModel(
                preferences: Preferences(defaults: defaults), now: Self.now, github: github.client, files: files,
                findTool: { _ in nil })
            await started(model, github)
            let limits = try #require(model.snapshot.accounts.first).limits
            #expect(limits.trouble == .toolMissing)
            #expect(limits.detail == "Claude Code was not found.")
            #expect(model.toolErrors.isEmpty)
        }
    }

    @Test func aToolsFolderThatCannotBeReadKeepsItsErrorAndTheAccountShowsTheToolMissing() async throws {
        try await withStub { github, files, defaults in
            try Account.save(
                [Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil)], to: files.accounts)
            try FileManager.default.createDirectory(at: files.tools, withIntermediateDirectories: true)
            try Data("not a folder".utf8).write(to: files.tools.appending(path: "claude"))
            let model = AppModel(
                preferences: Preferences(defaults: defaults), now: Self.now, github: github.client, files: files,
                findTool: { _ in nil })
            await started(model, github)
            #expect(model.snapshot.accounts.first?.limits.trouble == .toolMissing)
            #expect(model.toolErrors[.claude] != nil)
        }
    }

    @Test func theRingShowsTheFullestLimit() async throws {
        try await withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            #expect(AppModel(preferences: preferences, now: Self.now).ring == .none)
            #expect(
                AppModel(snapshot: stage("day"), preferences: preferences, now: Self.now).ring == .used(0.52, .normal))
            #expect(
                AppModel(snapshot: stage("limit"), preferences: preferences, now: Self.now).ring == .used(0.91, .near))
        }
    }

    @Test(arguments: statuses) func theStatusSaysHowOldTheListIs(
        reading: (readSecondsAgo: TimeInterval?, trouble: Snapshot.Trouble?, status: String)
    ) async throws {
        try await withDefaults { defaults in
            var snapshot = Snapshot.empty
            snapshot.pullRequests.readAt = reading.readSecondsAgo.map { Self.now - $0 }
            snapshot.pullRequests.askedAt = Self.now
            snapshot.pullRequests.trouble = reading.trouble
            let model = AppModel(snapshot: snapshot, preferences: Preferences(defaults: defaults), now: Self.now)
            #expect(model.status == reading.status)
            #expect(model.isOffline == reading.status.hasPrefix("Offline"))
        }
    }

    @Test func aShownSnapshotStaysAsItWasSaved() async throws {
        let model = AppModel(showing: stageFile("offline"))
        #expect(model.now == Self.now)
        #expect(model.status == "Offline. Updated 14m ago")
        #expect(model.list.openCount == 7)
        #expect(model.accounts.map(\.name) == ["Work", "Personal", "Codex"])
        #expect(model.ring == .used(0.52, .normal))

        await model.refresh(.all)
        model.panelOpened()
        await settled(model)
        #expect(model.snapshot == stage("offline"))
        #expect(model.now == Self.now)
    }
}
