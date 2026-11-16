import AppKit
import SandbarCore
import SandbarUI
import Testing

struct SpokenTests {
    nonisolated static let icons: [(icon: Icon, name: String)] = [
        (.merging, "Merging"), (.draft, "Draft"), (.changesRequested, "Changes requested"), (.approved, "Approved"),
        (.open, "Open"), (.checkPassed, "Checks passed"), (.checkRunning, "Checks running"),
        (.checkFailed, "Checks failed"), (.refresh, "Refresh"), (.gear, "Menu"), (.fewer, "Show fewer"),
        (.stack, "Stack"), (.gitHub, "GitHub"), (.claude, "Claude"), (.codex, "Codex"),
    ]

    nonisolated static let rows: [(pullRequest: PullRequest, time: Preferences.TimeShown, sentence: String)] = [
        (
            pullRequest("Cache the cart total", 4812, decision: .approved), .sinceOpened,
            "Approved, Cache the cart total, checks passed, number 4812, 3 days"
        ),
        (
            pullRequest("Cache the cart total", 4812, decision: .approved), .sinceUpdate,
            "Approved, Cache the cart total, checks passed, number 4812, 2 hours"
        ),
        (
            pullRequest("Cache the cart total", 4812, decision: .approved), .off,
            "Approved, Cache the cart total, checks passed, number 4812"
        ),
        (
            pullRequest("Fix the weather word\non the delivery estimate", 12, checks: nil, isDraft: true), .sinceOpened,
            "Draft, Fix the weather word on the delivery estimate, number 12, 3 days"
        ),
        (
            pullRequest("Tidy the receipt layout", 7, decision: .changesRequested, checks: .failed), .sinceOpened,
            "Changes requested, Tidy the receipt layout, checks failed, number 7, 3 days"
        ),
        (
            pullRequest("Remove the dashboard's time override", 40790, checks: .running, isInMergeQueue: true),
            .sinceOpened, "Merging, Remove the dashboard's time override, checks running, number 40790, 3 days"
        ),
        (
            pullRequest("Show the delivery date", 9), .sinceOpened,
            "Open, Show the delivery date, checks passed, number 9, 3 days"
        ),
    ]

    nonisolated static let work = Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil)
    nonisolated static let personal = Account(tool: .codex, name: "Personal", plan: "Plus", profile: nil)
    nonisolated static let usageRows: [(limit: UsageLimit?, account: Account, trouble: String?, sentence: String)] = [
        (
            UsageLimit(window: .month, used: 0.62, dollars: 3120, resetsAt: AppModelTests.now + 18 * 86_400 + 21_600),
            work, nil, "Claude Code, Work, Month, 3120 dollars, 62 percent, 18 days 6 hours left"
        ),
        (
            UsageLimit(window: .fiveHours, used: 0.12, resetsAt: AppModelTests.now + 11_520), personal, nil,
            "Codex, Personal, 5 hours, 12 percent, 3 hours 12 minutes left"
        ),
        (UsageLimit(window: .fiveHours, model: "Fable", used: 0.5), work, nil, "Claude Code, Work, Fable, 50 percent"),
        (nil, work, nil, "Claude Code, Work"),
        (
            UsageLimit(window: .week, used: 0.41, resetsAt: AppModelTests.now + 2 * 86_400 + 14_400), work,
            "Signed out.", "Claude Code, Work, Week, 41 percent, 2 days 4 hours left, Signed out."
        ),
        (nil, personal, "Codex was not found.", "Codex, Personal, Codex was not found."),
    ]

    private nonisolated static func pullRequest(
        _ title: String, _ number: Int, author: String = "kd", decision: PullRequest.Verdict? = nil,
        checks: Checks.Verdict? = .passed, isDraft: Bool = false, isInMergeQueue: Bool = false
    ) -> PullRequest {
        PullRequest(
            id: "PR_acme/storefront#\(number)", number: number, title: title,
            url: URL(string: "https://github.com/acme/storefront/pull/\(number)")!, repository: "acme/storefront",
            baseBranch: "main", headBranch: "change-\(number)", author: PullRequest.Author(login: author, picture: nil),
            createdAt: AppModelTests.now - 3 * 86_400, updatedAt: AppModelTests.now - 7_200, isDraft: isDraft,
            isInMergeQueue: isInMergeQueue, decision: decision, reviews: [], checks: Checks(verdict: checks),
            stack: nil)
    }

    @Test(arguments: icons) func everyIconHasItsSpokenName(icon: Icon, name: String) {
        #expect(icon.spoken == name)
    }

    @Test(arguments: rows) func aPullRequestRowReadsStateTitleChecksNumberAndTime(
        pullRequest: PullRequest, time: Preferences.TimeShown, sentence: String
    ) {
        #expect(spoken(pullRequest, now: AppModelTests.now, time: time) == sentence)
    }

    @Test func aReviewRequestSaysWhoAskedInPlaceOfItsState() {
        let request = Self.pullRequest(
            "Stop the importer from retrying uploads that already failed twice", 6821, author: "mchen")
        #expect(
            spoken(reviewRequest: request, now: AppModelTests.now, time: .sinceOpened)
                == "Review requested by mchen, Stop the importer from retrying uploads that already failed twice, "
                + "checks passed, number 6821, 3 days")
    }

    @Test func aFoldRowSaysHowManyMoreAndTheRowOfAnOpenStackOffersFewer() throws {
        let list = PullRequestList(mine: stage("many").pullRequests.value.mine, reviewRequests: [])
        let stackOfFive = try #require(
            list.mine.compactMap { entry in
                if case .stack(let stack) = entry, stack.pullRequests.count == 5 { stack } else { nil }
            }.first)
        #expect(spoken(foldRowOf: stackOfFive, isOpen: false) == "3 more in this stack")
        #expect(spoken(foldRowOf: stackOfFive, isOpen: true) == "Show fewer")
    }

    @Test(arguments: usageRows) func aUsageRowReadsToolNameWindowAmountTimeLeftAndItsTrouble(
        limit: UsageLimit?, account: Account, trouble: String?, sentence: String
    ) {
        #expect(spoken(limit, of: account, trouble: trouble, now: AppModelTests.now) == sentence)
    }

    @Test func theMenuBarItemSaysItsNameAndHowManyPullRequestsAreOpen() {
        let item = StatusItem(onClick: {}, onSession: { _ in })
        item.show(ring: .none, count: nil, dimmed: false)
        #expect(item.button?.accessibilityLabel() == "Sandbar")
        item.show(ring: .used(0.41, .normal), count: 12, dimmed: false)
        #expect(item.button?.accessibilityLabel() == "Sandbar, 12 open pull requests")
        item.show(ring: .used(0.41, .normal), count: 1, dimmed: false)
        #expect(item.button?.accessibilityLabel() == "Sandbar, 1 open pull request")
    }
}
