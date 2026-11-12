import AppKit
import SandbarCore
import SandbarTestSupport
import SandbarUI
import Testing

func withDefaults(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
    let suite = "sandbar-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try await body(defaults)
}

func afterSetup(_ defaults: UserDefaults) -> Preferences {
    let preferences = Preferences(defaults: defaults)
    preferences.isSetUp = true
    preferences.gitHubLogin = "kd"
    return preferences
}

func eventually(_ what: Comment, _ isSo: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await isSo()) {
        try #require(ContinuousClock.now < deadline, what)
        try await Task.sleep(for: .milliseconds(2))
    }
}

actor GitHubStub {
    static let deviceCode = """
        {"device_code": "3584d83530557fdd1f46af8289938c8ef79f9dc5", "user_code": "WDJB-MJHT",
         "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 5}
        """
    static let token = #"{"access_token": "gho_madeup", "token_type": "bearer", "scope": "repo"}"#
    static let pullRequests = """
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
    private(set) var tokens: [String] = []
    private var tokenAnswers: [String] = []
    private var lists = GitHubStub.pullRequests
    private var held: CheckedContinuation<Void, Never>?
    private var holdsNext = false
    private var holdsTheLogin = false

    nonisolated var send: GitHubClient.Send {
        { request in try await self.answer(request) }
    }

    func holdNext() {
        holdsNext = true
    }

    func holdTheLogin() {
        holdsTheLogin = true
    }

    func release() {
        held?.resume()
        held = nil
    }

    func answerTheCodeWith(_ answers: String...) {
        tokenAnswers = answers
    }

    func answerPullRequestsWith(_ answer: String) {
        lists = answer
    }

    private func answer(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let address = try #require(request.url)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let answer: String
        switch address.path {
        case "/login/device/code":
            answer = Self.deviceCode
        case "/login/oauth/access_token":
            answer = tokenAnswers.isEmpty ? #"{"error": "authorization_pending"}"# : tokenAnswers.removeFirst()
        case _ where body.contains("viewer"):
            tokens.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            if holdsTheLogin {
                holdsTheLogin = false
                await withCheckedContinuation { held = $0 }
            }
            answer = #"{"data": {"viewer": {"login": "kd"}}}"#
        default:
            requests += 1
            tokens.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            if holdsNext {
                holdsNext = false
                await withCheckedContinuation { held = $0 }
            }
            answer = lists
        }
        let response = try #require(
            HTTPURLResponse(url: address, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(answer.utf8), response)
    }
}

@MainActor final class Home {
    let defaults: UserDefaults
    let files: AppModel.Files
    let keychainItem = "test-\(UUID().uuidString)"
    private var made: [() -> AppModel?] = []

    static let noDownload: (URL) -> ToolDownload = { folder in
        ToolDownload(
            folder: folder, fetch: { _ in throw URLError(.notConnectedToInternet) },
            download: { _, _ in throw URLError(.notConnectedToInternet) }, sha256: { _ in "" })
    }

    init(defaults: UserDefaults, files: AppModel.Files) {
        self.defaults = defaults
        self.files = files
    }

    func model(
        snapshot: Snapshot = .empty, findTool: @escaping @Sendable (String) async -> URL? = { _ in nil },
        send: @escaping GitHubClient.Send = { _ in throw URLError(.notConnectedToInternet) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in },
        keychain: Keychain.Item? = nil, toolDownload: (URL) -> ToolDownload = Home.noDownload,
        openAddress: @escaping (URL) -> Void = { _ in }
    ) -> AppModel {
        let model = AppModel(
            snapshot: snapshot, preferences: Preferences(defaults: defaults), now: AppModelTests.now, files: files,
            findTool: findTool, send: send, sleep: sleep, keychain: keychain ?? Keychain.Item(named: keychainItem),
            toolDownload: toolDownload, openAddress: openAddress)
        made.append { [weak model] in model }
        return model
    }

    func settled() async throws {
        try await Task.sleep(for: .milliseconds(20))
        try await eventually("every refresh ends") { self.made.allSatisfy { $0()?.isRefreshing != true } }
    }
}

/// A folder, defaults and a Keychain item of their own; unless `fresh`, setup is finished and GitHub is connected as kd.
func withHome(fresh: Bool = false, _ body: @MainActor (Home) async throws -> Void) async throws {
    try await withDefaults { defaults in
        let folder = FileManager.default.temporaryDirectory.appending(path: "sandbar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let home = Home(defaults: defaults, files: AppModel.Files(folder: folder))
        defer { #expect(throws: Never.self) { try Keychain.delete(home.keychainItem) } }
        if !fresh {
            _ = afterSetup(defaults)
            try Keychain.write("made-up-token", as: home.keychainItem)
        }
        try await body(home)
        try await home.settled()  // a refresh still running would write into the folder after it is removed
    }
}

@Suite(.serialized) struct AppModelTests {
    static let now = Date(timeIntervalSince1970: 1_794_506_400)  // 2026-11-12 18:00 UTC

    nonisolated static let statuses: [(readSecondsAgo: TimeInterval?, trouble: Snapshot.Trouble?, status: String)] = [
        (59, nil, "Updated just now"), (60, nil, "Updated 1m ago"), (840, nil, "Updated 14m ago"),
        (840, .offline, "Offline. Updated 14m ago"), (840, .failed, "Offline. Updated 14m ago"),
        (840, .signedOut, "Updated 14m ago"), (nil, nil, ""), (nil, .signedOut, ""), (nil, .offline, "Offline."),
    ]

    private actor HeldLookup {
        private(set) var asks = 0
        private var held: CheckedContinuation<URL?, Never>?

        func find() async -> URL? {
            asks += 1
            return await withCheckedContinuation { held = $0 }
        }

        func answer(_ program: URL?) {
            held?.resume(returning: program)
            held = nil
        }
    }

    private static func signedOutClaude() throws -> URL {
        try FakeTool.script(named: "claude", #"[ "$*" = "auth status" ] && echo '{"loggedIn": false}'; exit 1"#)
    }

    private func withModel(
        _ body: @MainActor (AppModel, GitHubStub, AppModel.Files) async throws -> Void
    ) async throws {
        try await withHome { home in
            let github = GitHubStub()
            try await body(home.model(send: github.send), github, home.files)
        }
    }

    private func settled(_ model: AppModel) async throws {
        for _ in 0..<3 { await Task.yield() }
        try await eventually("the refresh ends") { !model.isRefreshing }
    }

    private func started(_ model: AppModel, _ github: GitHubStub) async throws {
        model.start()
        try await eventually("the first refresh ends") { await github.requests > 0 && !model.isRefreshing }
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
            #expect(!preferences.isSetUp)
            #expect(preferences.gitHubLogin == nil)
            #expect(!preferences.usesGhSignIn)
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
            preferences.isSetUp = true
            preferences.gitHubLogin = "kd"
            preferences.usesGhSignIn = true

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
            #expect(again.isSetUp)
            #expect(again.gitHubLogin == "kd")
            #expect(again.usesGhSignIn)

            again.chosenRepositories = nil
            again.time = .off
            again.gitHubLogin = nil
            #expect(Preferences(defaults: defaults).chosenRepositories == nil)
            #expect(Preferences(defaults: defaults).time == .off)
            #expect(Preferences(defaults: defaults).gitHubLogin == nil)
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
            Task { await model.refresh(.all) }
            try await eventually("GitHub is asked") { await github.requests > 0 }
            #expect(model.isRefreshing)
            #expect(model.status == "Updating…")

            await model.refresh(.all)
            #expect(await github.requests == 1)

            await github.release()
            try await eventually("the refresh ends") { !model.isRefreshing }
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
            try await settled(model)
            #expect(await github.requests == 1)

            model.now = Self.now + 16
            model.panelOpened()
            try await settled(model)
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
            try await settled(model)
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
            try await settled(model)
            #expect(await github.requests == 1)

            model.hasNetwork = true
            try await settled(model)
            #expect(await github.requests == 2)
            #expect(model.snapshot.pullRequests.readAt == Self.now + 840)
        }
    }

    @Test func nothingRefreshesBetweenSleepAndWake() async throws {
        try await withModel { model, github, _ in
            try await started(model, github)
            try #require(model.hasNetwork)
            let workspace = NSWorkspace.shared

            workspace.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: workspace)
            try await settled(model)
            model.now += 61
            await model.refreshWhatIsDue()
            let whileAsleep = await github.requests
            #expect(whileAsleep == 1)

            workspace.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: workspace)
            try await settled(model)
            #expect(await github.requests == whileAsleep + 1)
        }
    }

    @Test func aReleasedModelNoLongerHearsTheWake() async throws {
        try await withHome { home in
            let github = GitHubStub()
            weak var released: AppModel?
            do {
                let model = home.model(send: github.send)
                try await started(model, github)
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
            try await started(model, github)
            model.start()
            try await settled(model)
            #expect(await github.requests == 1)
        }
    }

    @Test func accountsLoadFromTheFileAndReachEveryRefresh() async throws {
        try await withHome { home in
            let github = GitHubStub()
            let accounts = [
                Account(tool: .codex, name: "Personal", plan: "Plus", profile: nil),
                Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil),
            ]
            try Account.save(accounts, to: home.files.accounts)
            let model = home.model(send: github.send)
            #expect(model.accounts.isEmpty)

            try await started(model, github)
            #expect(model.accounts == accounts)
            #expect(model.snapshot.accounts.map(\.account) == [accounts[1], accounts[0]])
            #expect(model.snapshot.accounts.allSatisfy { $0.limits.askedAt == Self.now })

            model.now = Self.now + 400
            await model.refresh(.all)
            #expect(model.snapshot.accounts.map(\.account) == [accounts[1], accounts[0]])
            #expect(model.snapshot.accounts.allSatisfy { $0.limits.askedAt == Self.now + 400 })
        }
    }

    @Test func aFoundToolIsTheOneTheRefreshRuns() async throws {
        try await withHome { home in
            let github = GitHubStub()
            try Account.save(
                [Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil)], to: home.files.accounts)
            let claude = try Self.signedOutClaude()
            let model = home.model(findTool: { name in name == "claude" ? claude : nil }, send: github.send)
            try await started(model, github)
            let limits = try #require(model.snapshot.accounts.first).limits
            #expect(limits.trouble == .signedOut)
            #expect(limits.detail == "Signed out.")
        }
    }

    @Test func aRefreshAskedForDuringTheToolLookupWaitsForIt() async throws {
        try await withHome { home in
            let github = GitHubStub()
            try Account.save(
                [Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil)], to: home.files.accounts)
            let claude = try Self.signedOutClaude()
            let lookup = HeldLookup()
            let model = home.model(
                findTool: { name in name == "claude" ? await lookup.find() : nil }, send: github.send)
            await github.holdNext()
            model.start()
            try await eventually("the lookup asks for Claude Code") { await lookup.asks == 1 }
            model.panelOpened()
            for _ in 0..<10 { await Task.yield() }

            await lookup.answer(claude)
            try await eventually("GitHub is asked") { await github.requests > 0 }
            await github.release()
            try await settled(model)
            let limits = try #require(model.snapshot.accounts.first).limits
            #expect(limits.trouble == .signedOut)
            #expect(limits.detail == "Signed out.")
        }
    }

    @Test func aRefreshWaitsForALookupStartedWhileItWaited() async throws {
        try await withHome { home in
            let github = GitHubStub()
            Preferences(defaults: home.defaults).isSetUp = false
            try Account.save(
                [Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil)], to: home.files.accounts)
            let claude = try Self.signedOutClaude()
            let lookup = HeldLookup()
            let model = home.model(
                findTool: { name in name == "claude" ? await lookup.find() : nil }, send: github.send)
            await github.holdNext()
            model.start()
            try await eventually("the first lookup asks for Claude Code") { await lookup.asks == 1 }

            model.panelOpened()
            await lookup.answer(nil)
            try await eventually("the second lookup asks for Claude Code") { await lookup.asks == 2 }
            #expect(await github.requests == 0, "the refresh still waits")

            await lookup.answer(claude)
            try await eventually("GitHub is asked") { await github.requests == 1 }
            await github.release()
            try await settled(model)
            let limits = try #require(model.snapshot.accounts.first).limits
            #expect(limits.trouble == .signedOut)
            #expect(limits.detail == "Signed out.")
        }
    }

    @Test func aLimitsRefreshOwedDuringAnotherRunsWhenThatOneEnds() async throws {
        try await withHome { home in
            let github = GitHubStub()
            let model = home.model(
                findTool: Fake.found(["claude": try Fake.claude(ownSignIn: true)]), send: github.send)
            try await started(model, github)
            await github.holdNext()
            Task { await model.refresh(.pullRequests) }
            try await eventually("GitHub is asked again") { await github.requests == 2 }

            await model.useExisting(.claude)
            try #require(model.accounts.count == 1)
            #expect(model.snapshot.accounts.isEmpty)

            await github.release()
            try await eventually("both refreshes end") { !model.isRefreshing }
            #expect(model.snapshot.accounts.first?.limits.value.map(\.label) == ["Week"])
            #expect(model.snapshot.accounts.first?.limits.askedAt == Self.now)
        }
    }

    @Test func aToolFoundNowhereReachesTheSnapshotAsMissing() async throws {
        try await withHome { home in
            let github = GitHubStub()
            try Account.save(
                [Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil)], to: home.files.accounts)
            let model = home.model(send: github.send)
            try await started(model, github)
            let limits = try #require(model.snapshot.accounts.first).limits
            #expect(limits.trouble == .toolMissing)
            #expect(limits.detail == "Claude Code was not found.")
            #expect(model.toolErrors.isEmpty)
        }
    }

    @Test func aToolsFolderThatCannotBeReadKeepsItsErrorAndTheAccountShowsTheToolMissing() async throws {
        try await withHome { home in
            let github = GitHubStub()
            let files = home.files
            try Account.save(
                [Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil)], to: files.accounts)
            try FileManager.default.createDirectory(at: files.tools, withIntermediateDirectories: true)
            try Data("not a folder".utf8).write(to: files.tools.appending(path: "claude"))
            let model = home.model(send: github.send)
            try await started(model, github)
            #expect(model.snapshot.accounts.first?.limits.trouble == .toolMissing)
            #expect(model.toolErrors[.claude] != nil)
        }
    }

    @Test func anOldCopyOfSandbarsIsRenewedAtMostOnceADay() async throws {
        try await withHome { home in
            let github = GitHubStub()
            try Account.save(
                [Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil)], to: home.files.accounts)
            let old = try Fake.keep(try Fake.claude(), asSandbarsCopyOf: .claude, version: "2.1.400", in: home.files)
            try FileManager.default.setAttributes([.modificationDate: Self.now - 14 * 86_400], ofItemAtPath: old.path)
            let maker = Maker(version: "2.1.401", giving: try Fake.claude(ownSignIn: true))
            let model = home.model(send: github.send, toolDownload: maker.download)
            try await started(model, github)
            #expect(model.snapshot.accounts.first?.limits.trouble == .signedOut)
            #expect(await maker.asked == 0)

            await model.refreshWhatIsDue()
            try await eventually("the limits are read through the new copy") {
                model.snapshot.accounts.first?.limits.value.map(\.label) == ["Week"]
            }
            #expect(await maker.asked == 1)
            let copies = home.files.tools.appending(path: "claude")
            #expect(try FileManager.default.contentsOfDirectory(atPath: copies.path) == ["2.1.401"])

            let new = copies.appending(path: "2.1.401/claude")
            try FileManager.default.setAttributes([.modificationDate: Self.now - 14 * 86_400], ofItemAtPath: new.path)
            model.now = Self.now + 86_399
            await model.refreshWhatIsDue()
            try await home.settled()
            #expect(await maker.asked == 1, "within the day")

            model.now = Self.now + 86_400
            await model.refreshWhatIsDue()
            try await eventually("the maker is asked again") { await maker.asked == 2 }
        }
    }

    @Test func sandbarsCopyIsLeftAloneWhileTheUserHasTheTool() async throws {
        try await withHome { home in
            let github = GitHubStub()
            try Account.save(
                [Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil)], to: home.files.accounts)
            let old = try Fake.keep(try Fake.claude(), asSandbarsCopyOf: .claude, version: "2.1.400", in: home.files)
            try FileManager.default.setAttributes([.modificationDate: Self.now - 14 * 86_400], ofItemAtPath: old.path)
            let maker = Maker(version: "2.1.401", giving: try Fake.claude())
            let model = home.model(
                findTool: Fake.found(["claude": try Fake.claude(ownSignIn: true)]), send: github.send,
                toolDownload: maker.download)
            try await started(model, github)
            #expect(model.snapshot.accounts.first?.limits.value.map(\.label) == ["Week"])

            await model.refreshWhatIsDue()
            try await home.settled()
            #expect(await maker.asked == 0)
        }
    }

    @Test func aFailedReadingThroughSandbarsCopyAsksTheMakerOncePerFailure() async throws {
        try await withHome { home in
            let github = GitHubStub()
            try Account.save(
                [Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil)], to: home.files.accounts)
            let breaks =
                #"if [ -e "$(dirname "$0")/mended" ]; then \#(Fake.usageReport); else echo broken >&2; exit 3; fi"#
            let copy = try Fake.keep(
                try Fake.claude(ownSignIn: true, usage: breaks), asSandbarsCopyOf: .claude, version: "2.1.400",
                in: home.files)
            let maker = Maker()
            let model = home.model(send: github.send, toolDownload: maker.download)
            try await started(model, github)
            try await eventually("the maker is asked") { await maker.asked == 1 }
            try await home.settled()
            #expect(model.snapshot.accounts.first?.limits.trouble == .failed)

            model.now = Self.now + 400
            await model.refresh(.all)
            try await home.settled()
            #expect(await maker.asked == 1, "once while it stays broken")

            try Data().write(to: Fake.beside(copy, "mended"))
            model.now = Self.now + 800
            await model.refresh(.all)
            #expect(model.snapshot.accounts.first?.limits.trouble == nil)

            try FileManager.default.removeItem(at: Fake.beside(copy, "mended"))
            model.now = Self.now + 1_200
            await model.refresh(.all)
            try await eventually("the maker is asked again") { await maker.asked == 2 }
        }
    }

    @Test func oneRenewalOfACopyRunsAtATime() async throws {
        try await withHome { home in
            let github = GitHubStub()
            try Account.save(
                [Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil)], to: home.files.accounts)
            let old = try Fake.keep(
                try Fake.claude(ownSignIn: true, usage: "exit 3"), asSandbarsCopyOf: .claude, version: "2.1.400",
                in: home.files)
            try FileManager.default.setAttributes([.modificationDate: Self.now - 14 * 86_400], ofItemAtPath: old.path)
            let answers = Gate()
            let maker = Maker(gate: answers)
            let model = home.model(send: github.send, toolDownload: maker.download)
            try await started(model, github)
            try await eventually("the failed reading asks the maker") { await maker.asked == 1 }

            await model.refreshWhatIsDue()
            try await Task.sleep(for: .milliseconds(50))
            #expect(await maker.asked == 1, "the old copy's turn waits for the renewal in flight")
            await answers.open()
        }
    }

    @Test func aRenewalThatFailsKeepsTheCopyAndItsError() async throws {
        try await withHome { home in
            let github = GitHubStub()
            try Account.save(
                [Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil)], to: home.files.accounts)
            let old = try Fake.keep(
                try Fake.claude(ownSignIn: true), asSandbarsCopyOf: .claude, version: "2.1.400", in: home.files)
            try FileManager.default.setAttributes([.modificationDate: Self.now - 14 * 86_400], ofItemAtPath: old.path)
            let model = home.model(send: github.send)
            try await started(model, github)
            #expect(model.toolErrors.isEmpty)

            await model.refreshWhatIsDue()
            try await eventually("the failure is kept") { model.toolErrors[.claude] != nil }
            #expect(model.snapshot.accounts.first?.limits.value.map(\.label) == ["Week"])
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
        try await settled(model)
        #expect(model.snapshot == stage("offline"))
        #expect(model.now == Self.now)
    }
}
