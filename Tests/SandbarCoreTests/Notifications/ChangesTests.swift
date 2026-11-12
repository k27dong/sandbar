import Foundation
import SandbarCore
import Testing

struct ChangesTests {
    static let readAt = Sample.now - 60
    static let personal = Account(tool: .claude, name: "Personal", plan: "Max", profile: nil)
    static let work = Account(tool: .codex, name: "Work", plan: "Business", profile: nil)

    static func snapshot(
        mine: [PullRequest] = [], reviewRequests: [PullRequest] = [], accounts: [Snapshot.AccountLimits] = [],
        read: Date? = readAt
    ) -> Snapshot {
        var snapshot = Snapshot.empty
        snapshot.pullRequests = .init(
            value: PullRequestLists(mine: mine, reviewRequests: reviewRequests, hiddenOrganizations: []),
            readAt: read)
        snapshot.accounts = accounts
        return snapshot
    }

    static func limits(_ account: Account, _ limits: [UsageLimit], read: Date? = readAt) -> Snapshot.AccountLimits {
        Snapshot.AccountLimits(account: account, limits: .init(value: limits, readAt: read))
    }

    static func review(_ author: String, _ verdict: PullRequest.Verdict, minutesAgo: Double = 10)
        -> PullRequest.Review
    {
        PullRequest.Review(author: author, verdict: verdict, submittedAt: Sample.now - minutesAgo * 60)
    }

    static func changes(from old: Snapshot, to new: Snapshot, in parts: Snapshot.Parts = .all) -> [Change] {
        new.changes(since: old, in: parts)
    }

    @Test func anOldSnapshotNeverReadGivesNothing() {
        let old = Self.snapshot(read: nil)
        let approved = PullRequest.sample(1, decision: .approved, reviews: [Self.review("mchen", .approved)])
        let new = Self.snapshot(mine: [approved], reviewRequests: [.sample(2)])
        #expect(Self.changes(from: old, to: new).isEmpty)
        let unreadLimits = Self.snapshot(accounts: [
            Self.limits(Self.personal, [.init(window: .week, used: 0.5)], read: nil)
        ])
        let nearer = Self.snapshot(accounts: [Self.limits(Self.personal, [.init(window: .week, used: 0.9)])])
        #expect(Self.changes(from: unreadLimits, to: nearer).isEmpty)
    }

    @Test func aNewSnapshotNeverReadGivesNothing() {
        let old = Self.snapshot(mine: [.sample(1)])
        let new = Self.snapshot(
            mine: [.sample(1, decision: .approved, reviews: [Self.review("mchen", .approved)])], read: nil)
        #expect(Self.changes(from: old, to: new).isEmpty)
    }

    @Test func aPullRequestTurningApprovedGivesApprovedByTheReviewer() {
        let approved = PullRequest.sample(1, decision: .approved, reviews: [Self.review("mchen", .approved)])
        let changes = Self.changes(from: Self.snapshot(mine: [.sample(1)]), to: Self.snapshot(mine: [approved]))
        #expect(changes == [.approved(approved, by: "mchen")])
    }

    @Test func approvedAgainGivesNothing() {
        let approved = PullRequest.sample(1, decision: .approved, reviews: [Self.review("mchen", .approved)])
        let again = PullRequest.sample(
            1, decision: .approved,
            reviews: [Self.review("mchen", .approved), Self.review("priya", .approved, minutesAgo: 1)])
        #expect(Self.changes(from: Self.snapshot(mine: [approved]), to: Self.snapshot(mine: [again])).isEmpty)
    }

    @Test func approvingReviewsWithoutADecisionStillGiveApproved() {
        let approved = PullRequest.sample(1, decision: nil, reviews: [Self.review("priya", .approved)])
        let changes = Self.changes(from: Self.snapshot(mine: [.sample(1)]), to: Self.snapshot(mine: [approved]))
        #expect(changes == [.approved(approved, by: "priya")])
    }

    @Test func theNewestApprovingReviewNamesTheApprover() {
        let approved = PullRequest.sample(
            1, decision: .approved,
            reviews: [
                Self.review("priya", .approved, minutesAgo: 30), Self.review("mchen", .approved, minutesAgo: 5),
                Self.review("dana", .changesRequested, minutesAgo: 1),
            ])
        let changes = Self.changes(from: Self.snapshot(mine: [.sample(1)]), to: Self.snapshot(mine: [approved]))
        #expect(changes == [.approved(approved, by: "mchen")])
    }

    @Test func approvedWithoutAnyReviewNamesNobody() {
        let approved = PullRequest.sample(1, decision: .approved)
        let changes = Self.changes(from: Self.snapshot(mine: [.sample(1)]), to: Self.snapshot(mine: [approved]))
        #expect(changes == [.approved(approved, by: nil)])
    }

    @Test func changesRequestedNamesTheNewestReviewerWhoAskedForThem() {
        let asked = PullRequest.sample(
            1, decision: .changesRequested,
            reviews: [
                Self.review("priya", .changesRequested, minutesAgo: 30),
                Self.review("dana", .changesRequested, minutesAgo: 5),
                Self.review("mchen", .approved, minutesAgo: 1),
            ])
        let changes = Self.changes(from: Self.snapshot(mine: [.sample(1)]), to: Self.snapshot(mine: [asked]))
        #expect(changes == [.changesRequested(asked, by: "dana")])
    }

    @Test func aPullRequestGoingFromChangesRequestedToApprovedGivesApproved() {
        let asked = PullRequest.sample(
            1, decision: .changesRequested, reviews: [Self.review("dana", .changesRequested)])
        let approved = PullRequest.sample(1, decision: .approved, reviews: [Self.review("dana", .approved)])
        let changes = Self.changes(from: Self.snapshot(mine: [asked]), to: Self.snapshot(mine: [approved]))
        #expect(changes == [.approved(approved, by: "dana")])
    }

    @Test func aPullRequestGoingFromApprovedToChangesRequestedGivesChangesRequested() {
        let approved = PullRequest.sample(1, decision: .approved, reviews: [Self.review("mchen", .approved)])
        let asked = PullRequest.sample(
            1, decision: .changesRequested,
            reviews: [Self.review("mchen", .approved), Self.review("dana", .changesRequested)])
        let changes = Self.changes(from: Self.snapshot(mine: [approved]), to: Self.snapshot(mine: [asked]))
        #expect(changes == [.changesRequested(asked, by: "dana")])
    }

    @Test(arguments: [Checks.Verdict.passed, .running, nil]) func checksTurningFailedGiveChecksFailed(
        before: Checks.Verdict?
    ) {
        let old = PullRequest.sample(1, checks: Checks(verdict: before))
        let new = PullRequest.sample(1, checks: Checks(verdict: .failed, failed: ["e2e-chrome"]))
        #expect(Self.changes(from: Self.snapshot(mine: [old]), to: Self.snapshot(mine: [new])) == [.checksFailed(new)])
    }

    @Test func checksStillFailedGiveNothing() {
        let old = PullRequest.sample(1, checks: Checks(verdict: .failed, failed: ["e2e-chrome"]))
        let new = PullRequest.sample(1, checks: Checks(verdict: .failed, failed: ["e2e-chrome", "lint"]))
        #expect(Self.changes(from: Self.snapshot(mine: [old]), to: Self.snapshot(mine: [new])).isEmpty)
    }

    @Test func checksTurningPassedGiveNothing() {
        let old = PullRequest.sample(1, checks: Checks(verdict: .failed, failed: ["lint"]))
        let new = PullRequest.sample(1, checks: Checks(verdict: .passed))
        #expect(Self.changes(from: Self.snapshot(mine: [old]), to: Self.snapshot(mine: [new])).isEmpty)
    }

    @Test func aPullRequestSeenForTheFirstTimeGivesNothing() {
        let new = PullRequest.sample(
            2, decision: .approved, reviews: [Self.review("mchen", .approved)],
            checks: Checks(verdict: .failed, failed: ["lint"]))
        #expect(
            Self.changes(from: Self.snapshot(mine: [.sample(1)]), to: Self.snapshot(mine: [.sample(1), new])).isEmpty)
    }

    @Test func aNewReviewRequestGivesReviewRequested() {
        let kept = PullRequest.sample(3, author: "mchen")
        let added = PullRequest.sample(4, author: "dana")
        let changes = Self.changes(
            from: Self.snapshot(reviewRequests: [kept]), to: Self.snapshot(reviewRequests: [kept, added]))
        #expect(changes == [.reviewRequested(added)])
    }

    @Test func aReviewRequestMovingToMineGivesNothing() {
        let request = PullRequest.sample(3, author: "mchen")
        #expect(
            Self.changes(from: Self.snapshot(reviewRequests: [request]), to: Self.snapshot(reviewRequests: [request]))
                .isEmpty)
    }

    @Test func aPullRequestOfAnotherPersonIsNotWatchedForApproval() {
        let old = PullRequest.sample(3, author: "mchen")
        let new = PullRequest.sample(3, author: "mchen", decision: .approved, reviews: [Self.review("dana", .approved)])
        #expect(
            Self.changes(from: Self.snapshot(reviewRequests: [old]), to: Self.snapshot(reviewRequests: [new])).isEmpty)
    }

    @Test func crossingEightyPercentGivesLimitNear() {
        let before = UsageLimit(window: .week, used: 0.79, resetsAt: Sample.now + 86_400)
        let after = UsageLimit(window: .week, used: 0.80, resetsAt: Sample.now + 86_400)
        let changes = Self.changes(
            from: Self.snapshot(accounts: [Self.limits(Self.personal, [before])]),
            to: Self.snapshot(accounts: [Self.limits(Self.personal, [after])]))
        #expect(changes == [.limitNear(account: "Personal", limit: after)])
    }

    @Test func stayingAboveEightyPercentGivesNothing() {
        let before = UsageLimit(window: .week, used: 0.85, resetsAt: Sample.now + 86_400)
        let after = UsageLimit(window: .week, used: 0.90, resetsAt: Sample.now + 86_400)
        let changes = Self.changes(
            from: Self.snapshot(accounts: [Self.limits(Self.personal, [before])]),
            to: Self.snapshot(accounts: [Self.limits(Self.personal, [after])]))
        #expect(changes.isEmpty)
    }

    @Test func aMonthLimitWithoutResetTimeFallingGivesLimitReset() {
        let before = UsageLimit(window: .month, used: 0.62, dollars: 3_120)
        let after = UsageLimit(window: .month, used: 0.02, dollars: 100)
        let changes = Self.changes(
            from: Self.snapshot(accounts: [Self.limits(Self.personal, [before])]),
            to: Self.snapshot(accounts: [Self.limits(Self.personal, [after])]))
        #expect(changes == [.limitReset(account: "Personal", limit: after)])
    }

    @Test func aWeekLimitWithAResetTimeFallingGivesNothing() {
        let before = UsageLimit(window: .week, used: 0.62, resetsAt: Sample.now - 60)
        let after = UsageLimit(window: .week, used: 0.02, resetsAt: Sample.now + 7 * 86_400)
        let changes = Self.changes(
            from: Self.snapshot(accounts: [Self.limits(Self.personal, [before])]),
            to: Self.snapshot(accounts: [Self.limits(Self.personal, [after])]))
        #expect(changes.isEmpty)
    }

    @Test func aLimitRisingWithoutCrossingGivesNothing() {
        let before = UsageLimit(window: .month, used: 0.20)
        let after = UsageLimit(window: .month, used: 0.30)
        let changes = Self.changes(
            from: Self.snapshot(accounts: [Self.limits(Self.personal, [before])]),
            to: Self.snapshot(accounts: [Self.limits(Self.personal, [after])]))
        #expect(changes.isEmpty)
    }

    @Test func limitsAreMatchedByAccountWindowAndModel() {
        let weekAll = UsageLimit(window: .week, used: 0.85, resetsAt: Sample.now + 86_400)
        let weekFableBefore = UsageLimit(window: .week, model: "Fable", used: 0.79, resetsAt: Sample.now + 86_400)
        let weekFableAfter = UsageLimit(window: .week, model: "Fable", used: 0.81, resetsAt: Sample.now + 86_400.4)
        let workBefore = UsageLimit(window: .week, model: "Fable", used: 0.90)
        let workAfter = UsageLimit(window: .week, model: "Fable", used: 0.95)
        let old = Self.snapshot(accounts: [
            Self.limits(Self.personal, [weekAll, weekFableBefore]), Self.limits(Self.work, [workBefore]),
        ])
        let new = Self.snapshot(accounts: [
            Self.limits(Self.work, [workAfter]), Self.limits(Self.personal, [weekAll, weekFableAfter]),
        ])
        #expect(Self.changes(from: old, to: new) == [.limitNear(account: "Personal", limit: weekFableAfter)])
    }

    @Test func anAccountOrLimitNotInTheOldSnapshotGivesNothing() {
        let old = Self.snapshot(accounts: [Self.limits(Self.personal, [.init(window: .week, used: 0.10)])])
        let new = Self.snapshot(accounts: [
            Self.limits(Self.personal, [.init(window: .week, used: 0.10), .init(window: .fiveHours, used: 0.95)]),
            Self.limits(Self.work, [.init(window: .week, used: 0.95)]),
        ])
        #expect(Self.changes(from: old, to: new).isEmpty)
    }

    @Test func onlyThePartsNamedAreLookedAt() {
        let approved = PullRequest.sample(1, decision: .approved, reviews: [Self.review("mchen", .approved)])
        let old = Self.snapshot(
            mine: [.sample(1)], accounts: [Self.limits(Self.personal, [.init(window: .week, used: 0.79)])])
        let new = Self.snapshot(
            mine: [approved], accounts: [Self.limits(Self.personal, [.init(window: .week, used: 0.9)])])
        #expect(Self.changes(from: old, to: new, in: .limits).count == 1)
        #expect(Self.changes(from: old, to: new, in: .pullRequests) == [.approved(approved, by: "mchen")])
        #expect(Self.changes(from: old, to: new, in: []).isEmpty)
        #expect(Self.changes(from: old, to: new).count == 2)
    }
}
