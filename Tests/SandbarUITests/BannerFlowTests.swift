import Foundation
import SandbarCore
import SandbarTestSupport
import SandbarUI
import Testing

@MainActor final class HandedBanners {
    var delivered: [Banner] = []
    var scheduled: [[Banner]] = []
    var permissionAsks = 0

    func handedOver(by refreshes: Int) async throws {
        try await eventually("macOS is handed what \(refreshes) refreshes made") { scheduled.count >= refreshes }
    }

    var delivery: BannerDelivery {
        BannerDelivery(
            deliver: { [self] in delivered += $0 }, schedule: { [self] in scheduled.append($0) },
            askPermission: { [self] in permissionAsks += 1 })
    }
}

@Suite(.serialized) struct BannerFlowTests {
    static let waiting = GitHubStub.pullRequests.replacingOccurrences(
        of: #""reviewDecision": "APPROVED""#, with: #""reviewDecision": "REVIEW_REQUIRED""#)
    static let approvedByMchen = GitHubStub.pullRequests.replacingOccurrences(
        of: #""latestOpinionatedReviews": {"nodes": []}"#,
        with: #"""
            "latestOpinionatedReviews": {"nodes": [
              {"state": "APPROVED", "submittedAt": "2026-11-12T17:30:00Z", "author": {"login": "mchen"}}]}
            """#)

    private static func resets(at now: Date) -> [Banner] {
        Banner.resets(in: stage("day"), settings: NotificationSettings(), now: now)
    }

    @Test func theFirstRefreshDeliversNothingThoughTheSavedCopyDiffers() async throws {
        try await withHome { home in
            let github = GitHubStub()
            await github.answerPullRequestsWith(Self.waiting)
            let earlier = home.model(send: github.send)
            try await ends("the earlier run's refresh ends") { await earlier.refresh(.all) }
            try #require(SavedSnapshot.read(from: home.files.snapshot).pullRequests.value.mine.first?.verdict == nil)

            await github.answerPullRequestsWith(Self.approvedByMchen)
            let banners = HandedBanners()
            let model = home.model(send: github.send, banners: banners.delivery)
            model.start()
            try await eventually("the first refresh ends") { await github.requests == 2 && !model.isRefreshing }
            #expect(model.list.mine.first?.lead.verdict == .approved)
            try await banners.handedOver(by: 1)
            #expect(banners.delivered.isEmpty)
        }
    }

    @Test func aPullRequestThatTurnsApprovedDeliversOneBanner() async throws {
        try await withHome { home in
            let github = GitHubStub()
            await github.answerPullRequestsWith(Self.waiting)
            let banners = HandedBanners()
            let model = home.model(send: github.send, banners: banners.delivery)
            try await ends("the first refresh ends") { await model.refresh(.all) }
            try await banners.handedOver(by: 1)
            #expect(banners.delivered.isEmpty)

            await github.answerPullRequestsWith(Self.approvedByMchen)
            try await ends("the second refresh ends") { await model.refresh(.all) }
            try await banners.handedOver(by: 2)
            #expect(banners.delivered.map(\.title) == ["Approved by mchen"])
            #expect(banners.delivered.map(\.body) == ["Read saved carts through one cart reader"])
            #expect(
                banners.delivered.map(\.opens) == [
                    .pullRequest(try #require(URL(string: "https://github.com/acme/storefront/pull/41250")))
                ])
        }
    }

    @Test func whilePausedNothingIsDeliveredAndNothingIsScheduled() async throws {
        try await withHome { home in
            Preferences(defaults: home.defaults).notificationsPaused = true
            let github = GitHubStub()
            await github.answerPullRequestsWith(Self.waiting)
            let banners = HandedBanners()
            let model = home.model(snapshot: stage("day"), send: github.send, banners: banners.delivery)
            try await ends("the first refresh ends") { await model.refresh(.all) }
            await github.answerPullRequestsWith(Self.approvedByMchen)
            try await ends("the second refresh ends") { await model.refresh(.all) }
            try await banners.handedOver(by: 2)
            #expect(model.list.mine.first?.lead.verdict == .approved)
            #expect(banners.delivered.isEmpty)
            #expect(banners.scheduled == [[], []])
        }
    }

    @Test func pausingClearsTheResetsAndUnpausingSchedulesThemAgain() async throws {
        try await withHome { home in
            let banners = HandedBanners()
            let model = home.model(snapshot: stage("day"), send: GitHubStub().send, banners: banners.delivery)
            try await ends("the refresh ends") { await model.refresh(.pullRequests) }
            try await banners.handedOver(by: 1)
            try #require(banners.scheduled == [Self.resets(at: AppModelTests.now)])

            model.notificationsPaused = true
            #expect(Preferences(defaults: home.defaults).notificationsPaused)
            try await eventually("the resets are taken back") { banners.scheduled.count == 2 }
            #expect(banners.scheduled.last == [])

            model.notificationsPaused = false
            #expect(!Preferences(defaults: home.defaults).notificationsPaused)
            try await eventually("the resets are scheduled again") { banners.scheduled.count == 3 }
            #expect(banners.scheduled.last == Self.resets(at: AppModelTests.now))
            #expect(banners.scheduled.last?.count == 4)
        }
    }

    @Test func afterASignOutAndANewSignInTheNextRefreshDeliversNothing() async throws {
        try await withHome { home in
            let github = GitHubStub()
            await github.answerPullRequestsWith(Self.waiting)
            let banners = HandedBanners()
            let model = home.model(send: github.send, banners: banners.delivery)
            try await ends("the first refresh ends") { await model.refresh(.all) }
            try await ends("the second refresh ends") { await model.refresh(.all) }

            model.signOutOfGitHub()
            await github.answerPullRequestsWith(Self.approvedByMchen)
            await github.answerTheCodeWith(GitHubStub.token)
            try await ends("the code sign-in ends") { await model.connectGitHub() }
            try await eventually("the refresh after the sign-in ends") {
                await github.requests == 3 && !model.isRefreshing
            }
            #expect(model.list.mine.first?.lead.verdict == .approved)
            try await banners.handedOver(by: 3)
            #expect(banners.delivered.isEmpty)
        }
    }

    @Test func aSwitchToGhsSignInMakesTheNextRefreshSilent() async throws {
        try await withHome { home in
            Preferences(defaults: home.defaults).isSetUp = false
            let github = GitHubStub()
            await github.answerPullRequestsWith(Self.waiting)
            let banners = HandedBanners()
            let model = home.model(
                findTool: Fake.found(["gh": try Fake.gh()]), send: github.send, banners: banners.delivery)
            model.panelOpened()
            try await eventually("gh is found signed in") { model.canUseGh }
            try await home.settled()
            try await ends("the second refresh ends") { await model.refresh(.all) }
            try #require(await github.requests == 2)

            await github.answerPullRequestsWith(Self.approvedByMchen)
            try await ends("gh's sign-in ends") { await model.useGhSignIn() }
            try await eventually("the refresh after the switch ends") {
                await github.requests == 3 && !model.isRefreshing
            }
            try await banners.handedOver(by: 3)
            #expect(model.list.mine.first?.lead.verdict == .approved)
            #expect(banners.delivered.isEmpty)
        }
    }

    @Test func everyRefreshHandsOverTheResetsOfTheSnapshotItLeaves() async throws {
        try await withHome { home in
            let banners = HandedBanners()
            let model = home.model(snapshot: stage("day"), send: GitHubStub().send, banners: banners.delivery)
            try await ends("the first refresh ends") { await model.refresh(.all) }
            try await banners.handedOver(by: 1)
            #expect(banners.scheduled == [Self.resets(at: AppModelTests.now)])
            #expect(banners.scheduled.last?.count == 4)

            model.now = AppModelTests.now + 4 * 3600
            try await ends("the second refresh ends") { await model.refresh(.pullRequests) }
            try await banners.handedOver(by: 2)
            #expect(banners.scheduled.count == 2)
            #expect(banners.scheduled.last == Self.resets(at: AppModelTests.now + 4 * 3600))
            #expect(banners.scheduled.last?.count == 3, "the five-hour limit has reset by then")
        }
    }

    /// A Claude Code whose weekly use, per profile folder name ("own" without one), is read from a file beside it.
    private static func claude() throws -> (program: URL, set: (String, String) throws -> Void) {
        let program = try Fake.claude(
            ownSignIn: true,
            usage: #"""
                who="$(basename "${CLAUDE_CONFIG_DIR:-own}")"
                [ -e "$(dirname "$0")/$who-fails" ] && exit 1
                echo "{\"usage_report\":{\"rate_limits\":{\"limits\":[{\"group\":\"weekly\",\"percent\":$(cat "$(dirname "$0")/$who-percent")}],\"extra_usage\":{\"is_enabled\":false}}}}"
                """#)
        let set = { (who: String, percent: String) throws in
            let fails = Fake.beside(program, "\(who)-fails")
            if percent == "fails" {
                try Data().write(to: fails)
            } else {
                if FileManager.default.fileExists(atPath: fails.path) { try FileManager.default.removeItem(at: fails) }
                try Data(percent.utf8).write(to: Fake.beside(program, "\(who)-percent"))
            }
        }
        return (program, set)
    }

    private static func account(_ name: String, profile: String?, in home: Home) throws -> Account {
        guard let profile else { return Account(tool: .claude, name: name, plan: "Pro", profile: nil) }
        let folder = home.files.profiles.appending(path: profile, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "signed-in"))
        return Account(tool: .claude, name: name, plan: "Pro", profile: folder)
    }

    private static func saveAnEarlierRun(_ accounts: [Account], used: Double, in home: Home) throws {
        var snapshot = Snapshot.empty
        snapshot.accounts = accounts.map { account in
            Snapshot.AccountLimits(
                account: account,
                limits: Snapshot.Reading(
                    value: [UsageLimit(window: .week, used: used)], readAt: AppModelTests.now - 600))
        }
        try SavedSnapshot.write(snapshot, to: home.files.snapshot)
        try Account.save(accounts, to: home.files.accounts)
    }

    @Test func anAccountWhoseFirstReadFailedIsSilentOnItsFirstGoodReadAndAnnouncesAfter() async throws {
        try await withHome { home in
            Preferences(defaults: home.defaults).notifications.limitNear = true
            let claude = try Self.claude()
            let work = try Self.account("Work", profile: nil, in: home)
            try Self.saveAnEarlierRun([work], used: 0.5, in: home)
            try claude.set("own", "fails")
            let banners = HandedBanners()
            let model = home.model(findTool: Fake.found(["claude": claude.program]), banners: banners.delivery)
            model.start()
            try await settled(model)
            try #require(model.snapshot.accounts.first?.limits.trouble == .failed)
            try claude.set("own", "90")
            try await ends("the first good read ends") { await model.refresh(.limits) }
            try await banners.handedOver(by: 2)
            try #require(model.snapshot.accounts.first?.limits.value.first?.used == 0.9)
            #expect(banners.delivered.isEmpty)

            try claude.set("own", "50")
            try await ends("a read under the line ends") { await model.refresh(.limits) }
            try claude.set("own", "85")
            try await ends("a read over the line ends") { await model.refresh(.limits) }
            try await banners.handedOver(by: 4)
            #expect(
                banners.delivered.map(\.title) == ["Limit reset", "85% used"], "a drop with no reset time is a reset")
            #expect(banners.delivered.map(\.body) == ["Work · Week", "Work · Week"])
        }
    }

    @Test func anotherAccountKeepsAnnouncingWhileOneFails() async throws {
        try await withHome { home in
            Preferences(defaults: home.defaults).notifications.limitNear = true
            let claude = try Self.claude()
            let work = try Self.account("Work", profile: nil, in: home)
            let personal = try Self.account("Personal", profile: "personal", in: home)
            try claude.set("own", "fails")
            try claude.set("personal", "50")
            try Self.saveAnEarlierRun([work, personal], used: 0.5, in: home)
            let banners = HandedBanners()
            let model = home.model(findTool: Fake.found(["claude": claude.program]), banners: banners.delivery)
            model.start()
            try await settled(model)
            try #require(model.snapshot.accounts.map(\.limits.trouble) == [.failed, nil])

            try claude.set("personal", "90")
            try await ends("the second read ends") { await model.refresh(.limits) }
            try await banners.handedOver(by: 2)
            #expect(banners.delivered.map(\.title) == ["90% used"])
            #expect(banners.delivered.map(\.body) == ["Personal · Week"])
        }
    }

    @Test func anAddedAccountIsSilentOnceAndTheOthersKeepAnnouncing() async throws {
        try await withHome { home in
            Preferences(defaults: home.defaults).notifications.limitNear = true
            let claude = try Self.claude()
            let work = try Self.account("Work", profile: "work", in: home)
            try claude.set("work", "50")
            try claude.set("own", "90")
            try Self.saveAnEarlierRun([work], used: 0.5, in: home)
            let banners = HandedBanners()
            let model = home.model(findTool: Fake.found(["claude": claude.program]), banners: banners.delivery)
            model.start()
            try await settled(model)

            try claude.set("work", "90")
            try await ends("the sign-in on this Mac is taken") { await model.useExisting(.claude) }
            try #require(model.accounts.count == 2)
            try await eventually("the added account is read") {
                model.snapshot.accounts.count == 2 && !model.isRefreshing
            }
            #expect(model.snapshot.accounts.map { $0.limits.value.first?.used } == [0.9, 0.9])
            try await banners.handedOver(by: 3)
            #expect(banners.delivered.map(\.title) == ["90% used"])
            #expect(banners.delivered.map(\.body) == ["Work · Week"])
        }
    }

    private func settled(_ model: AppModel) async throws {
        for _ in 0..<3 { await Task.yield() }
        try await eventually("the refresh ends") { !model.isRefreshing }
    }

    @Test func aRefreshDoesNotWaitForMacOSToTakeTheBanners() async throws {
        try await withHome { home in
            let github = GitHubStub()
            let macOS = Gate()
            let delivery = BannerDelivery(
                deliver: { _ in await macOS.wait() }, schedule: { _ in await macOS.wait() }, askPermission: {})
            let model = home.model(send: github.send, banners: delivery)
            try await ends("the first refresh ends") { await model.refresh(.all) }
            try await ends("the next refresh ends") { await model.refresh(.all) }
            #expect(await github.requests == 2)
            await macOS.open()
        }
    }

    @Test func removingAnAccountTakesItsResetsBackWithoutARefresh() async throws {
        try await withHome { home in
            let banners = HandedBanners()
            let model = home.model(snapshot: stage("day"), banners: banners.delivery)
            model.hasNetwork = false
            let codex = try #require(model.accounts.first { $0.name == "Codex" })

            try await ends("the removal ends") { await model.remove(codex) }
            try #require(!model.accounts.contains(codex))
            try await eventually("the resets are handed over again") { !banners.scheduled.isEmpty }
            var left = stage("day")
            left.accounts.removeAll { $0.id == codex.id }
            #expect(
                banners.scheduled.last
                    == Banner.resets(in: left, settings: NotificationSettings(), now: AppModelTests.now))
            #expect(banners.scheduled.last?.count == 2)
        }
    }

    nonisolated static let places: [(item: NSRect, screen: NSRect, isInMenuBar: Bool)] = [
        (NSRect(x: 0, y: 0, width: 40, height: 30), NSRect(x: 0, y: 0, width: 1440, height: 900), false),
        (NSRect(x: 1200, y: 870, width: 40, height: 30), NSRect(x: 0, y: 0, width: 1440, height: 900), true),
        (NSRect(x: 2000, y: 1050, width: 40, height: 30), NSRect(x: 1440, y: 0, width: 1920, height: 1080), true),
        (NSRect(x: -500, y: 1050, width: 40, height: 30), NSRect(x: -1920, y: 0, width: 1920, height: 1080), true),
        (NSRect(x: 1200, y: 1050, width: 40, height: 30), NSRect(x: 1440, y: 0, width: 1920, height: 1080), false),
        (NSRect(x: 1693, y: 1408, width: 27, height: 33), NSRect(x: 0, y: 0, width: 2560, height: 1440), true),
    ]

    @Test(arguments: places) func theItemHasItsPlaceOnlyAtTheTopOfItsScreen(
        item: NSRect, screen: NSRect, isInMenuBar: Bool
    ) {
        #expect(StatusItem.isInMenuBar(item, of: screen) == isInMenuBar)
    }

    @Test func finishingSetupAsksForPermissionOnce() async throws {
        try await withHome(fresh: true) { home in
            let banners = HandedBanners()
            let model = home.model(banners: banners.delivery)
            #expect(banners.permissionAsks == 0)
            model.finishSetup()
            model.finishSetup()
            try await eventually("permission is asked for") { banners.permissionAsks > 0 }
            for _ in 0..<10 { await Task.yield() }
            #expect(banners.permissionAsks == 1)
        }
    }
}
