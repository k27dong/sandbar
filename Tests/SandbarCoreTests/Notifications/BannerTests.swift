import Foundation
import SandbarCore
import Testing

struct BannerTests {
    static let retry = PullRequest.sample(1, title: "Retry webhook deliveries with backoff")
    static let cache = PullRequest.sample(2, title: "Cache the cart total", repository: "acme/api")
    static let tidy = PullRequest.sample(3, title: "Tidy the receipt layout", repository: "acme/tools")
    static let personalWeek = UsageLimit(window: .week, used: 0.02)
    static let personalFable = UsageLimit(window: .week, model: "Fable", used: 0.01)
    static let nearWeek = UsageLimit(window: .week, used: 0.8, resetsAt: Sample.now + 2 * 86_400 + 4 * 3_600)
    static let nearMonth = UsageLimit(window: .month, used: 0.83, dollars: 4_150)

    static func lines(_ changes: [Change], settings: NotificationSettings = NotificationSettings()) -> [[String]] {
        Banner.now(for: changes, settings: settings, at: Sample.now).map { [$0.title, $0.body] }
    }

    static let textCases: [(changes: [Change], lines: [String])] = [
        ([.approved(retry, by: "mchen")], ["Approved by mchen", "Retry webhook deliveries with backoff"]),
        ([.approved(retry, by: nil)], ["Approved", "Retry webhook deliveries with backoff"]),
        (
            [.approved(retry, by: "mchen"), .approved(cache, by: "mchen"), .approved(tidy, by: "mchen")],
            ["Approved by mchen", "Retry webhook deliveries with backoff and 2 more"]
        ),
        (
            [.approved(retry, by: "mchen"), .approved(cache, by: "mchen"), .approved(tidy, by: "priya")],
            ["Approved", "Retry webhook deliveries with backoff and 2 more"]
        ),
        (
            [.approved(retry, by: "mchen"), .approved(cache, by: nil)],
            ["Approved", "Retry webhook deliveries with backoff and 1 more"]
        ),
        (
            [.changesRequested(cache, by: "priya")],
            ["Changes requested by priya", "Cache the cart total"]
        ),
        (
            [.changesRequested(cache, by: "priya"), .changesRequested(tidy, by: "priya")],
            ["Changes requested by priya", "Cache the cart total and 1 more"]
        ),
        (
            [.changesRequested(cache, by: "priya"), .changesRequested(tidy, by: "dana")],
            ["Changes requested", "Cache the cart total and 1 more"]
        ),
        (
            [.checksFailed(failing(tidy, ["e2e-chrome"]))],
            ["e2e-chrome failed", "Tidy the receipt layout"]
        ),
        (
            [.checksFailed(failing(tidy, ["e2e-chrome", "lint", "unit"]))],
            ["3 checks failed", "Tidy the receipt layout"]
        ),
        (
            [.checksFailed(failing(tidy, ["e2e-chrome"])), .checksFailed(failing(cache, ["lint"]))],
            ["Checks failed", "Tidy the receipt layout and 1 more"]
        ),
        (
            [.reviewRequested(PullRequest.sample(4, title: "Tidy the receipt layout", author: "dana"))],
            ["Review requested by dana", "Tidy the receipt layout"]
        ),
        (
            [
                .reviewRequested(PullRequest.sample(4, title: "Cache the cart total", author: "dana")),
                .reviewRequested(PullRequest.sample(5, title: "Tidy the receipt layout", author: "dana")),
                .reviewRequested(PullRequest.sample(6, title: "Retry webhook deliveries", author: "dana")),
            ],
            ["Review requested by dana", "Cache the cart total and 2 more"]
        ),
        (
            [
                .reviewRequested(PullRequest.sample(4, title: "Cache the cart total", author: "dana")),
                .reviewRequested(PullRequest.sample(5, title: "Tidy the receipt layout", author: "mchen")),
            ],
            ["Review requested", "Cache the cart total and 1 more"]
        ),
        (
            [.limitReset(account: Self.personal, limit: personalWeek)],
            ["Limit reset", "Personal · Week"]
        ),
        (
            [
                .limitReset(account: Self.personal, limit: personalWeek),
                .limitReset(account: Self.personal, limit: personalFable),
            ],
            ["Limit reset", "Personal · Week, Fable"]
        ),
        (
            [.limitNear(account: Self.personal, limit: nearWeek)],
            ["80% used", "Personal · Week · 2d4h left"]
        ),
        (
            [.limitNear(account: Self.personal, limit: nearMonth)],
            ["83% used", "Personal · Month · \(ShortTime.left(until: monthEnd, from: Sample.now)) left"]
        ),
        (
            [.limitNear(account: Self.work, limit: UsageLimit(window: .other("mystery_group"), used: 0.9))],
            ["90% used", "Work · Mystery group"]
        ),
    ]

    static let monthEnd = Date(timeIntervalSince1970: 1_796_083_200)  // 2026-12-01 00:00 UTC

    static func failing(_ pullRequest: PullRequest, _ names: [String]) -> PullRequest {
        var failing = pullRequest
        failing.checks = Checks(verdict: .failed, failed: names)
        return failing
    }

    @Test(arguments: textCases) func theTextOfEachKind(changes: [Change], lines: [String]) {
        var settings = NotificationSettings()
        settings.reviewRequested = true
        settings.limitNear = true
        #expect(Self.lines(changes, settings: settings) == [lines])
    }

    @Test func severalKindsComeInTheFixedOrderWhateverTheOrderGiven() {
        let changes: [Change] = [
            .limitNear(account: Self.personal, limit: Self.nearWeek),
            .reviewRequested(PullRequest.sample(4, title: "Cache the cart total", author: "dana")),
            .limitReset(account: Self.personal, limit: Self.personalWeek),
            .checksFailed(Self.failing(Self.tidy, ["lint"])),
            .changesRequested(Self.cache, by: "priya"),
            .approved(Self.retry, by: "mchen"),
        ]
        var settings = NotificationSettings()
        settings.reviewRequested = true
        settings.limitNear = true
        let titles = Banner.now(for: changes, settings: settings, at: Sample.now).map(\.title)
        #expect(
            titles == [
                "Approved by mchen", "Changes requested by priya", "lint failed", "Review requested by dana",
                "Limit reset", "80% used",
            ])
    }

    @Test func limitResetsGiveOneBannerPerAccountAndLimitsNearOnePerLimit() {
        let changes: [Change] = [
            .limitReset(account: Self.personal, limit: Self.personalWeek),
            .limitReset(account: Self.work, limit: Self.personalFable),
            .limitReset(account: Self.personal, limit: Self.personalFable),
            .limitNear(account: Self.personal, limit: Self.nearWeek),
            .limitNear(account: Self.personal, limit: Self.nearMonth),
        ]
        var settings = NotificationSettings()
        settings.limitNear = true
        let banners = Banner.now(for: changes, settings: settings, at: Sample.now)
        #expect(
            banners.map(\.body) == [
                "Personal · Week, Fable", "Work · Fable", "Personal · Week · 2d4h left",
                "Personal · Month · \(ShortTime.left(until: Self.monthEnd, from: Sample.now)) left",
            ])
        #expect(Set(banners.map(\.id)).count == banners.count)
    }

    @Test func twoAccountsWithTheSameNameEachGetTheirOwnBanner() {
        let namesake = Account(tool: .codex, name: "Personal", plan: "Plus", profile: nil)
        var settings = NotificationSettings()
        settings.limitNear = true
        let banners = Banner.now(
            for: [
                .limitReset(account: Self.personal, limit: Self.personalWeek),
                .limitReset(account: namesake, limit: Self.personalWeek),
                .limitNear(account: Self.personal, limit: Self.nearWeek),
                .limitNear(account: namesake, limit: Self.nearWeek),
            ], settings: settings, at: Sample.now)
        #expect(
            banners.map(\.body) == [
                "Personal · Week", "Personal · Week", "Personal · Week · 2d4h left", "Personal · Week · 2d4h left",
            ])
        #expect(
            banners.map(\.id) == [
                "limit-reset-\(Self.personal.id.uuidString)-1794506400",
                "limit-reset-\(namesake.id.uuidString)-1794506400",
                "limit-near-\(Self.personal.id.uuidString)-Week-1794506400",
                "limit-near-\(namesake.id.uuidString)-Week-1794506400",
            ])
    }

    @Test func aKindSwitchedOffIsMissingAndTheOthersStay() {
        let changes: [Change] = [
            .approved(Self.retry, by: "mchen"), .changesRequested(Self.cache, by: "priya"),
            .checksFailed(Self.failing(Self.tidy, ["lint"])),
            .limitReset(account: Self.personal, limit: Self.personalWeek),
        ]
        var settings = NotificationSettings()
        settings.changesRequested = false
        #expect(
            Self.lines(changes, settings: settings).map(\.first) == [
                "Approved by mchen", "lint failed", "Limit reset",
            ])
    }

    @Test func kindsSwitchedOffByDefaultGiveNothing() {
        let changes: [Change] = [
            .reviewRequested(Self.cache), .limitNear(account: Self.personal, limit: Self.nearWeek),
        ]
        #expect(Self.lines(changes).isEmpty)
    }

    @Test func everySwitchTurnsOffItsOwnKind() {
        let changes: [Change] = [
            .approved(Self.retry, by: "mchen"), .changesRequested(Self.cache, by: "priya"),
            .checksFailed(Self.failing(Self.tidy, ["lint"])), .reviewRequested(Self.cache),
            .limitReset(account: Self.personal, limit: Self.personalWeek),
            .limitNear(account: Self.personal, limit: Self.nearWeek),
        ]
        var everything = NotificationSettings()
        everything.reviewRequested = true
        everything.limitNear = true
        #expect(Banner.now(for: changes, settings: everything, at: Sample.now).count == 6)
        let switches: [WritableKeyPath<NotificationSettings, Bool>] = [
            \.approved, \.changesRequested, \.checksFailed, \.reviewRequested, \.limitReset, \.limitNear,
        ]
        for off in switches {
            var settings = everything
            settings[keyPath: off] = false
            #expect(Banner.now(for: changes, settings: settings, at: Sample.now).count == 5)
        }
    }

    @Test func noChangesGiveNoBanners() {
        #expect(Self.lines([]).isEmpty)
    }

    @Test func oneBannerOpensItsPullRequestAndSeveralOpenThePanel() throws {
        let one = Banner.now(
            for: [.approved(Self.retry, by: "mchen")], settings: NotificationSettings(), at: Sample.now)
        #expect(one.map(\.opens) == [.pullRequest(Self.retry.url)])
        let many = Banner.now(
            for: [
                .approved(Self.retry, by: "mchen"), .approved(Self.cache, by: "mchen"),
                .approved(Self.tidy, by: "mchen"),
            ], settings: NotificationSettings(), at: Sample.now)
        #expect(many.map(\.opens) == [.panel])
    }

    @Test func limitBannersOpenThePanel() {
        var settings = NotificationSettings()
        settings.limitNear = true
        let banners = Banner.now(
            for: [
                .limitReset(account: Self.personal, limit: Self.personalWeek),
                .limitNear(account: Self.personal, limit: Self.nearWeek),
            ], settings: settings, at: Sample.now)
        #expect(banners.map(\.opens) == [.panel, .panel])
    }

    @Test func bannersForNowAreDeliveredNowWithTheKindAndTheSecondInTheirId() {
        let banners = Banner.now(
            for: [.approved(Self.retry, by: "mchen"), .changesRequested(Self.cache, by: "priya")],
            settings: NotificationSettings(), at: Sample.now)
        #expect(banners.map(\.deliverAt) == [nil, nil])
        #expect(banners.map(\.id) == ["approved-1794506400", "changesRequested-1794506400"])
    }

    static let resetTime = Date(timeIntervalSince1970: 1_794_780_000)  // on a whole minute
    static let ultraWeek = UsageLimit(window: .week, used: 0.37, resetsAt: resetTime + 0.000323)
    static let ultraFable = UsageLimit(window: .week, model: "Fable", used: 0.12, resetsAt: resetTime + 0.000523)
    static let personal = Account(tool: .claude, name: "Personal", plan: "Max", profile: nil)
    static let work = Account(tool: .codex, name: "Work", plan: "Business", profile: nil)

    static func snapshot(_ accounts: [(Account, [UsageLimit])]) -> Snapshot {
        var snapshot = Snapshot.empty
        snapshot.accounts = accounts.map {
            Snapshot.AccountLimits(account: $0.0, limits: .init(value: $0.1, readAt: Sample.now))
        }
        return snapshot
    }

    @Test func limitsResettingTogetherGiveOneBannerDueAtTheResetTime() throws {
        let banners = Banner.resets(
            in: Self.snapshot([(Self.personal, [Self.ultraWeek, Self.ultraFable])]), settings: NotificationSettings(),
            now: Sample.now)
        let banner = try #require(banners.first)
        #expect(banners.count == 1)
        #expect([banner.title, banner.body] == ["Limit reset", "Personal · Week, Fable"])
        #expect(banner.opens == .panel)
        #expect(abs(try #require(banner.deliverAt).timeIntervalSince(Self.resetTime)) < 0.001)
        #expect(banner.id == "reset-\(Self.personal.id.uuidString)-\(1_794_780_000 / 60)")
    }

    @Test func limitsResettingInDifferentMinutesOrAccountsGiveTheirOwnBanners() {
        let later = UsageLimit(window: .fiveHours, used: 0.5, resetsAt: Self.resetTime + 120)
        let banners = Banner.resets(
            in: Self.snapshot([(Self.personal, [Self.ultraWeek, later]), (Self.work, [Self.ultraWeek])]),
            settings: NotificationSettings(), now: Sample.now)
        #expect(banners.map(\.body) == ["Personal · Week", "Personal · 5h", "Work · Week"])
        #expect(Set(banners.map(\.id)).count == 3)
    }

    @Test func aResetTimeAlreadyPastGivesNothing() {
        let past = UsageLimit(window: .week, used: 0.5, resetsAt: Sample.now - 1)
        let none = UsageLimit(window: .month, used: 0.5)
        let banners = Banner.resets(
            in: Self.snapshot([(Self.personal, [past, none])]), settings: NotificationSettings(), now: Sample.now)
        #expect(banners.isEmpty)
    }

    @Test func aPastLimitDoesNotHideAFutureOneInTheSameAccount() {
        let past = UsageLimit(window: .fiveHours, used: 0.5, resetsAt: Sample.now - 1)
        let banners = Banner.resets(
            in: Self.snapshot([(Self.personal, [past, Self.ultraWeek])]), settings: NotificationSettings(),
            now: Sample.now)
        #expect(banners.map(\.body) == ["Personal · Week"])
    }

    @Test func resetsGiveNothingWhenTheSwitchIsOff() {
        var settings = NotificationSettings()
        settings.limitReset = false
        #expect(
            Banner.resets(in: Self.snapshot([(Self.personal, [Self.ultraWeek])]), settings: settings, now: Sample.now)
                .isEmpty)
    }

    @Test func theSameSnapshotTwiceGivesEqualIds() {
        let snapshot = Self.snapshot([(Self.personal, [Self.ultraWeek, Self.ultraFable])])
        let first = Banner.resets(in: snapshot, settings: NotificationSettings(), now: Sample.now)
        let second = Banner.resets(in: snapshot, settings: NotificationSettings(), now: Sample.now + 30)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(!first.isEmpty)
    }

    @Test func aResetTimeSavedWithoutFractionsGivesTheSameId() {
        let saved = UsageLimit(window: .week, used: 0.37, resetsAt: Self.resetTime)
        let live = Banner.resets(
            in: Self.snapshot([(Self.personal, [Self.ultraWeek])]), settings: NotificationSettings(), now: Sample.now)
        let reloaded = Banner.resets(
            in: Self.snapshot([(Self.personal, [saved])]), settings: NotificationSettings(), now: Sample.now)
        #expect(live.map(\.id) == reloaded.map(\.id))
    }
}
