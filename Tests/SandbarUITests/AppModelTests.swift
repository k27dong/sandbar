import AppKit
import SandbarCore
import SandbarTestSupport
import SandbarUI
import Testing

@Suite(.serialized) struct AppModelTests {
    nonisolated static let now = Date(timeIntervalSince1970: 1_794_506_400)  // 2026-11-12 18:00 UTC

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

    private actor Lookups {
        private(set) var count = 0

        func find(_ name: String) -> URL? {
            if name == "gh" { count += 1 }  // every lookup asks for gh once
            return nil
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
            try await ends("the refresh ends") { await model.refresh(.all) }
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

            try await ends("the refresh ends") { await model.refresh(.all) }
            #expect(await github.requests == 1)

            await github.release()
            try await eventually("the refresh ends") { !model.isRefreshing }
            #expect(await github.requests == 1)
            #expect(model.status == "Updated just now")
        }
    }

    @Test func theFooterSaysUpdatingFromTheMomentARefreshIsAskedFor() async throws {
        try await withHome { home in
            let github = GitHubStub()
            let lookup = HeldLookup()
            let model = home.model(
                findTool: { name in name == "claude" ? await lookup.find() : nil }, send: github.send)
            #expect(model.status == "")
            model.start()
            #expect(model.status == "Updating…", "asked for, not started yet")
            try await eventually("the lookup asks for Claude Code") { await lookup.asks == 1 }
            #expect(model.status == "Updating…", "waiting for the tool lookup")
            #expect(await github.requests == 0)
            await lookup.answer(nil)
            try await eventually("the refresh ends") { !model.isRefreshing }
            #expect(model.status == "Updated just now")
            #expect(await github.requests == 1)

            model.findSignIns()
            try await eventually("the second lookup asks for Claude Code") { await lookup.asks == 2 }
            Task { await model.refresh(.pullRequests) }
            try await eventually("the footer's own refresh waits for the lookup") { model.isRefreshing }
            #expect(model.status == "Updating…")
            #expect(await github.requests == 1)
            await lookup.answer(nil)
            try await eventually("the refresh ends") { !model.isRefreshing }
            #expect(await github.requests == 2)
        }
    }

    @Test func openingThePanelRefreshesUnlessTheLastAskIsUnder15SecondsOld() async throws {
        try await withModel { model, github, _ in
            try await ends("the refresh ends") { await model.refresh(.all) }
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
            try await ends("the refresh ends") { await model.refresh(.all) }
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
            try await ends("the refresh ends") { await model.refresh(.all) }
            model.hasNetwork = false

            model.now += 100
            try await ends("the refresh ends") { await model.refreshWhatIsDue() }
            #expect(await github.requests == 1, "the timer's turn")

            model.now += 100
            model.panelOpened()
            try await settled(model)
            #expect(await github.requests == 1, "opening the panel")

            try await ends("the refresh ends") { await model.refresh(.all) }
            #expect(await github.requests == 1, "the footer's button")
        }
    }

    @Test func theNetworkComingBackRefreshesAtOnce() async throws {
        try await withModel { model, github, _ in
            try await ends("the refresh ends") { await model.refresh(.all) }
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
            try await ends("the refresh ends") { await model.refreshWhatIsDue() }
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
            try await ends("the refresh ends") { await model.refresh(.all) }
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

            try await ends("the sign-in on this Mac is taken or refused") { await model.useExisting(.claude) }
            try #require(model.accounts.count == 1)
            try await Task.sleep(for: .milliseconds(100))  // the new refresh meets the one in flight, not its end
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
            let lookups = Lookups()
            let model = home.model(
                findTool: { await lookups.find($0) }, send: github.send, toolDownload: maker.download)
            try await started(model, github)
            #expect(model.snapshot.accounts.first?.limits.trouble == .signedOut)
            #expect(await maker.asked == 0)

            try await ends("the refresh ends") { await model.refreshWhatIsDue() }
            try await eventually("the limits are read through the new copy") {
                model.snapshot.accounts.first?.limits.value.map(\.label) == ["Week"]
            }
            #expect(await maker.asked == 1)
            let copies = home.files.tools.appending(path: "claude")
            #expect(try FileManager.default.contentsOfDirectory(atPath: copies.path) == ["2.1.401"])

            let new = copies.appending(path: "2.1.401/claude")
            try FileManager.default.setAttributes([.modificationDate: Self.now - 14 * 86_400], ofItemAtPath: new.path)
            model.now = Self.now + 86_399
            try await ends("the refresh ends") { await model.refreshWhatIsDue() }
            try await Task.sleep(for: .milliseconds(100))  // a renewal within the day would have asked the maker by now
            #expect(await maker.asked == 1, "within the day")

            model.now = Self.now + 86_400
            try await ends("the refresh ends") { await model.refreshWhatIsDue() }
            try await eventually("the maker is asked again") { await maker.asked == 2 }
            try await eventually("that renewal ends by looking for the tools again") { await lookups.count == 3 }
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

            try await ends("the refresh ends") { await model.refreshWhatIsDue() }
            try await Task.sleep(for: .milliseconds(100))  // a renewal would have asked the maker by now
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
            let lookups = Lookups()
            let model = home.model(
                findTool: { await lookups.find($0) }, send: github.send, toolDownload: maker.download)
            try await started(model, github)
            try await eventually("the maker is asked") { await maker.asked == 1 }
            try await eventually("that renewal ends by looking for the tools again") { await lookups.count == 2 }
            try await home.settled()
            #expect(model.snapshot.accounts.first?.limits.trouble == .failed)

            model.now = Self.now + 400
            try await ends("the refresh ends") { await model.refresh(.all) }
            try await Task.sleep(for: .milliseconds(100))  // a second renewal would have asked the maker by now
            #expect(await maker.asked == 1, "once while it stays broken")

            try Data().write(to: Fake.beside(copy, "mended"))
            model.now = Self.now + 800
            try await ends("the refresh ends") { await model.refresh(.all) }
            #expect(model.snapshot.accounts.first?.limits.trouble == nil)

            try FileManager.default.removeItem(at: Fake.beside(copy, "mended"))
            model.now = Self.now + 1_200
            try await ends("the refresh ends") { await model.refresh(.all) }
            try await eventually("the maker is asked again") { await maker.asked == 2 }
            try await eventually("that renewal ends by looking for the tools again") { await lookups.count == 3 }
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
            let lookups = Lookups()
            let model = home.model(
                findTool: { await lookups.find($0) }, send: github.send, toolDownload: maker.download)
            try await started(model, github)
            try await eventually("the failed reading asks the maker") { await maker.asked == 1 }

            try await ends("the refresh ends") { await model.refreshWhatIsDue() }
            try await Task.sleep(for: .milliseconds(50))
            #expect(await maker.asked == 1, "the old copy's turn waits for the renewal in flight")
            await answers.open()
            try await eventually("the renewal ends by looking for the tools again") { await lookups.count == 2 }
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

            try await ends("the refresh ends") { await model.refreshWhatIsDue() }
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

    @Test func setupIsFinishedOnceAndRemembered() async throws {
        try await withHome(fresh: true) { home in
            let model = home.model()
            #expect(!model.isSetUp)
            model.finishSetup()
            #expect(model.isSetUp)
            #expect(home.model().isSetUp)
        }
    }

    @Test func aShownSnapshotCountsAsSetUpWithNoSignInToAskFor() async throws {
        let model = AppModel(showing: stageFile("day"))
        #expect(model.isSetUp)
        #expect(!model.needsGitHubSignIn)
    }

    @Test func theFooterCountsWhatIsConnected() async throws {
        try await withHome(fresh: true) { home in
            #expect(home.model().setupStatus == "Nothing connected")

            Preferences(defaults: home.defaults).gitHubLogin = "kd"
            #expect(home.model().setupStatus == "1 of 3 connected")

            var snapshot = Snapshot.empty
            snapshot.accounts = [
                Snapshot.AccountLimits(
                    account: Account(tool: .codex, name: "Personal", plan: "Plus", profile: nil),
                    limits: Snapshot.Reading(value: []))
            ]
            #expect(home.model(snapshot: snapshot).setupStatus == "2 of 3 connected")

            snapshot.accounts += [
                Snapshot.AccountLimits(
                    account: Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil),
                    limits: Snapshot.Reading(value: [])),
                Snapshot.AccountLimits(
                    account: Account(tool: .claude, name: "Personal", plan: "Max", profile: nil),
                    limits: Snapshot.Reading(value: [])),
            ]
            #expect(home.model(snapshot: snapshot).setupStatus == "3 of 3 connected")
        }
    }

    @Test func aShownSnapshotStaysAsItWasSaved() async throws {
        let model = AppModel(showing: stageFile("offline"))
        #expect(model.now == Self.now)
        #expect(model.status == "Offline. Updated 14m ago")
        #expect(model.list.openCount == 7)
        #expect(model.accounts.map(\.name) == ["Work", "Personal", "Codex"])
        #expect(model.ring == .used(0.52, .normal))

        try await ends("the refresh ends") { await model.refresh(.all) }
        model.panelOpened()
        try await settled(model)
        #expect(model.snapshot == stage("offline"))
        #expect(model.now == Self.now)
    }

    @Test func theShortcutStartsAsOptionCommandPAndCanBeChangedOrCleared() async throws {
        try await withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            #expect(preferences.shortcut == .standard)
            let controlCommandK = Shortcut.Keys(keyCode: 40, modifiers: 4096 | 256)
            preferences.shortcut = controlCommandK
            #expect(Preferences(defaults: defaults).shortcut == controlCommandK)
            preferences.shortcut = nil
            #expect(Preferences(defaults: defaults).shortcut == nil)
        }
    }

    @Test func theShortcutSaysItsKeysInTheMacsOrder() {
        #expect(Shortcut.Keys.standard.text == "⌥⌘P")
        #expect(Shortcut.Keys(keyCode: 40, modifiers: 4096 | 256).text == "⌃⌘K")
        #expect(Shortcut.Keys(keyCode: 49, modifiers: 2048 | 512).text == "⌥⇧Space")
    }

    @Test func settingsReopenOnThePaneUsedLast() async throws {
        try await withDefaults { defaults in
            #expect(Preferences(defaults: defaults).settingsPane == .general)
            Preferences(defaults: defaults).settingsPane = .accounts
            #expect(Preferences(defaults: defaults).settingsPane == .accounts)
        }
    }

    @Test func finishingSetupSwitchesLaunchAtLoginOnTheFirstTimeOnly() async throws {
        try await withHome(fresh: true) { home in
            let model = home.model()
            #expect(!model.launchesAtLogin)
            model.finishSetup()
            #expect(home.loginItemAsked == [true])
            #expect(model.launchesAtLogin)
            #expect(model.launchAtLoginNote == nil)

            model.launchAtLogin(false)
            #expect(!model.launchesAtLogin)
            home.model().finishSetup()
            #expect(home.loginItemAsked == [true, false])
        }
    }

    @Test func aRefusedLoginItemIsSaidUnderTheSwitchWhichShowsTheTrueState() async throws {
        try await withHome(fresh: true) { home in
            home.loginItemRefuses = true
            let model = home.model()
            model.finishSetup()
            #expect(model.isSetUp)
            #expect(!model.launchesAtLogin)
            #expect(model.launchAtLoginNote?.hasPrefix("macOS did not change it: ") == true)
            #expect(home.loginItemAsked == [true])

            home.loginItemRefuses = false
            model.launchAtLogin(true)
            #expect(model.launchesAtLogin)
            #expect(model.launchAtLoginNote == nil)
        }
    }

    @Test func choosingRepositoriesStartsWithEveryListedOneAndHidesTheOthers() async throws {
        try await withHome { home in
            let model = home.model(snapshot: stage("day"))
            let everything = model.list.openCount
            #expect(!model.choosesRepositories)
            #expect(model.repositoryChoices == ["acme/api", "acme/storefront", "acme/tools"])

            model.choosesRepositories = true
            #expect(model.preferences.chosenRepositories == ["acme/api", "acme/storefront", "acme/tools"])
            #expect(model.list.openCount == everything)

            model.choose("acme/storefront", false)
            model.choose("acme/tools", false)
            #expect(model.preferences.chosenRepositories == ["acme/api"])
            #expect(model.list.openCount < everything)
            #expect(
                (model.list.mine.map(\.lead) + model.list.reviewRequests).allSatisfy { $0.repository == "acme/api" })

            model.choose("acme/web", true)
            #expect(model.repositoryChoices == ["acme/api", "acme/storefront", "acme/tools", "acme/web"])
            #expect(model.preferences.chosenRepositories == ["acme/api", "acme/web"])

            model.choosesRepositories = true
            #expect(model.preferences.chosenRepositories == ["acme/api", "acme/web"])
            model.choosesRepositories = false
            #expect(model.preferences.chosenRepositories == nil)
            #expect(model.list.openCount == everything)
        }
    }

    @Test func aShownSnapshotChangesNothingReal() async throws {
        try await withHome { home in
            let lookups = Lookups()
            let github = GitHubStub()
            let model = AppModel(
                showing: stageFile("day"), files: home.files, keychain: Keychain.Item(named: home.keychainItem),
                findTool: { await lookups.find($0) }, send: github.send, toolDownload: Home.noDownload)
            let accounts = model.accounts
            #expect(model.accountsAreLocked)
            #expect(!model.canRenameAccounts)
            #expect(home.model().canRenameAccounts)

            model.rename(accounts[0], to: "Renamed")
            try await ends("the remove does nothing") { await model.remove(accounts[1]) }
            try await ends("the sign-in does nothing") { await model.addAccount(.claude) }
            try await ends("taking the Mac's sign-in does nothing") { await model.useExisting(.codex) }
            try await ends("connecting does nothing") { await model.connectGitHub() }
            try await ends("taking gh's sign-in does nothing") { await model.useGhSignIn() }
            model.signOutOfGitHub()
            model.findSignIns()
            try await Task.sleep(for: .milliseconds(100))  // a lookup started by mistake would ask for gh by now

            #expect(model.accounts == accounts)
            #expect(model.gitHub == .none)
            #expect(model.signInStep == [.claude: .idle, .codex: .idle])
            #expect(try entries(of: home.files.accounts.deletingLastPathComponent()).isEmpty)
            #expect(try Keychain.read(home.keychainItem) == "made-up-token")
            #expect(await lookups.count == 0)
            #expect(await github.requests == 0)
        }
    }

    @Test func aShownSnapshotReadsAndSavesNoSettings() throws {
        let saved = UserDefaults.standard.string(forKey: "titles")
        let model = AppModel(showing: stageFile("day"))
        #expect(model.preferences.titles == .oneLine)
        model.preferences.titles = saved == "twoLines" ? .oneLine : .twoLines
        #expect(UserDefaults.standard.string(forKey: "titles") == saved)
        #expect(AppModel(showing: stageFile("day")).preferences.titles == .oneLine)
        #expect(!model.launchesAtLogin)
    }

    @Test func theLaunchAtLoginSwitchShowsAChangeMadeElsewhere() async throws {
        try await withHome { home in
            let model = home.model()
            #expect(!model.launchesAtLogin)
            home.launchesAtLogin = true
            model.checkLaunchAtLogin()
            #expect(model.launchesAtLogin)
        }
    }

    nonisolated static let takenKeys: [(modifiers: UInt32, isTaken: Bool)] = [
        (256, false), (256 | 512, false), (512, false), (0, false), (2048, true), (4096, true), (256 | 2048, true),
        (256 | 4096 | 512, true),
    ]

    @Test(arguments: takenKeys) func aShortcutNeedsControlOrOption(keys: (modifiers: UInt32, isTaken: Bool)) {
        #expect((Shortcut.Keys(taking: 8, modifiers: keys.modifiers) != nil) == keys.isTaken)
    }
}
