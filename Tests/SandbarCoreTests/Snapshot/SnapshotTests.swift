import Foundation
import SandbarCore
import SandbarTestSupport
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct SnapshotTests {
    static let lists = GitHubAnswer.list(
        mine: [GitHubAnswer.node(1), GitHubAnswer.node(2)], reviewRequests: [GitHubAnswer.node(3)])
    static let claudeWork = Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil)
    static let codexWork = Account(
        tool: .codex, name: "Work", plan: "Business", profile: URL(filePath: "/profiles/codex-work"))
    static let codexPersonal = Account(tool: .codex, name: "Personal", plan: "Plus", profile: nil)
    static let claudeWeek = UsageLimit(window: .week, used: 0.41)
    static let codexFiveHours = UsageLimit(window: .fiveHours, used: 0.17)
    static let codexWorkFiveHours = UsageLimit(window: .fiveHours, used: 0.23)

    static let quiet = PullRequestLists(mine: [.sample(1)], reviewRequests: [], hiddenOrganizations: [])
    static let reviewChecksRunning = PullRequestLists(
        mine: [.sample(1)], reviewRequests: [.sample(2, checks: Checks(verdict: .running))], hiddenOrganizations: [])
    static let ownChecksRunning = PullRequestLists(
        mine: [.sample(1, checks: Checks(verdict: .running))], reviewRequests: [.sample(2)], hiddenOrganizations: [])
    static let dueCases:
        [(
            lists: PullRequestLists, pullRequestsAskedAt: Date?, trouble: Snapshot.Trouble?, limitsAskedAt: [Date?],
            due: Snapshot.Parts
        )] = [
            (quiet, nil, nil, [nil], .all),
            (quiet, Sample.now - 59, nil, [Sample.now], []),
            (quiet, Sample.now - 60, nil, [Sample.now], .pullRequests),
            (reviewChecksRunning, Sample.now - 19, nil, [Sample.now], []),
            (reviewChecksRunning, Sample.now - 20, nil, [Sample.now], .pullRequests),
            (ownChecksRunning, Sample.now - 20, nil, [Sample.now], .pullRequests),
            (quiet, Sample.now, nil, [Sample.now - 299], []),
            (quiet, Sample.now, nil, [Sample.now - 300], .limits),
            (quiet, Sample.now, nil, [Sample.now, nil], .limits),
            (quiet, Sample.now - 10, .failed, [Sample.now], []),
        ]

    static let detailCases: [(error: any Error, tool: Tool?, sentence: String)] = [
        (GitHubError.signedOut, nil, "GitHub sign-in is missing or no longer valid."),
        (GitHubError.offline, nil, "GitHub could not be reached."),
        (GitHubError.rejected(status: 502, body: "Bad gateway"), nil, "GitHub answered with status 502."),
        (GitHubError.notUnderstood(#"{"data": null}"#), nil, "GitHub's answer was not understood."),
        (ToolError.missing, .claude, "Claude Code was not found."),
        (ToolError.missing, .codex, "Codex was not found."),
        (ToolError.signedOut, .claude, "Signed out."),
        (ToolError.signedOut, .codex, "Signed out."),
        (ToolError.timedOut, .claude, "Claude Code did not answer in time."),
        (ToolError.timedOut, .codex, "Codex did not answer in time."),
        (
            ToolError.failed(status: 1, output: "  Not logged in. Run claude auth login.\n"), .claude,
            "Not logged in. Run claude auth login."
        ),
        (ToolError.failed(status: 1, output: " \n"), .claude, "Claude Code ended with status 1."),
        (ToolError.failed(status: 2, output: ""), .codex, "Codex ended with status 2."),
        (ToolError.notUnderstood("hello"), .claude, "Claude Code's answer was not understood."),
        (ToolError.notUnderstood("hello"), .codex, "Codex's answer was not understood."),
        (ToolError.missing, nil, "The read failed."),
        (CancellationError(), .claude, "The read failed."),
        (DownloadError.failed("offline"), .claude, "Claude Code could not be fetched."),
        (DownloadError.checksum(expected: "aa11", got: "bb22"), .codex, "Codex could not be fetched."),
        (DownloadError.noBuild("darwin-arm64"), nil, "The read failed."),
    ]

    func github(_ exchange: GitHubExchange) -> GitHubClient {
        GitHubClient(token: { "T" }, send: exchange.send)
    }

    func claude(signedIn: Bool = true, percent: Int = 41) throws -> URL {
        try FakeTool.script(
            named: "claude",
            """
            case "$*" in
              "auth status") echo '{"loggedIn": \(signedIn)}'; [ \(signedIn) = true ] || exit 1 ;;
              *) echo '{"type":"assistant","usage_report":{"rate_limits":{"limits":[{"group":"weekly","percent":\(percent)}],"extra_usage":{"is_enabled":false}}}}' ;;
            esac
            """
        )
    }

    func codex() throws -> URL {
        try FakeTool.script(
            named: "codex-app-server",
            #"""
            while read -r line; do
              id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
              case "$CODEX_HOME" in */codex-work) used=23 ;; *) used=17 ;; esac
              case "$line" in
                *'"method":"initialize"'*) echo "{\"id\":$id,\"result\":{\"userAgent\":\"fake\"}}" ;;
                *'"method":"account/read"'*)
                  echo "{\"id\":$id,\"result\":{\"account\":{\"type\":\"chatgpt\",\"planType\":\"plus\"}}}" ;;
                *'"method":"account/rateLimits/read"'*)
                  echo "{\"id\":$id,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":$used,\"windowDurationMins\":300}}}}" ;;
              esac
            done
            """#
        )
    }

    @Test func aGoodReadFillsBothListsAndItsTimes() async {
        let snapshot = await Snapshot.empty.refreshed(
            .pullRequests, github: github(GitHubExchange(Self.lists)), accounts: [], tools: [:], now: Sample.now)
        #expect(snapshot.pullRequests.value.mine.map(\.number) == [1, 2])
        #expect(snapshot.pullRequests.value.reviewRequests.map(\.number) == [3])
        #expect(snapshot.pullRequests.readAt == Sample.now)
        #expect(snapshot.pullRequests.askedAt == Sample.now)
        #expect(snapshot.pullRequests.trouble == nil)
    }

    @Test func aFailedReadKeepsTheLastListsAndTheirTimeAndSaysWhy() async {
        let client = github(GitHubExchange([(200, Self.lists), (502, "Bad gateway"), (200, Self.lists)]))
        let first = await Snapshot.empty.refreshed(
            .pullRequests, github: client, accounts: [], tools: [:], now: Sample.now)
        let second = await first.refreshed(
            .pullRequests, github: client, accounts: [], tools: [:], now: Sample.now + 60)
        #expect(
            second.pullRequests
                == Snapshot.Reading(
                    value: first.pullRequests.value, readAt: Sample.now, askedAt: Sample.now + 60, trouble: .failed,
                    detail: "GitHub answered with status 502."))
        #expect(second.pullRequests.value.mine.count == 2)
        let third = await second.refreshed(
            .pullRequests, github: client, accounts: [], tools: [:], now: Sample.now + 120)
        #expect(third.pullRequests.trouble == nil)
        #expect(third.pullRequests.detail == nil)
        #expect(third.pullRequests.readAt == Sample.now + 120)
    }

    @Test func noClientIsSignedOut() async {
        let snapshot = await Snapshot.empty.refreshed(
            .pullRequests, github: nil, accounts: [], tools: [:], now: Sample.now)
        #expect(
            snapshot.pullRequests
                == Snapshot.Reading(
                    value: Snapshot.empty.pullRequests.value, askedAt: Sample.now, trouble: .signedOut,
                    detail: "GitHub sign-in is missing or no longer valid."))
    }

    @Test func noNetworkIsOffline() async {
        let client = GitHubClient(token: { "T" }, send: { _ in throw URLError(.notConnectedToInternet) })
        let snapshot = await Snapshot.empty.refreshed(
            .pullRequests, github: client, accounts: [], tools: [:], now: Sample.now)
        #expect(snapshot.pullRequests.trouble == .offline)
        #expect(snapshot.pullRequests.detail == "GitHub could not be reached.")
        #expect(snapshot.pullRequests.askedAt == Sample.now)
    }

    @Test func askingForLimitsLeavesThePullRequestsAlone() async throws {
        let client = github(GitHubExchange(Self.lists))
        let first = await Snapshot.empty.refreshed(
            .pullRequests, github: client, accounts: [], tools: [:], now: Sample.now)
        let second = await first.refreshed(
            .limits, github: client, accounts: [Self.claudeWork], tools: [.claude: try claude()],
            now: Sample.now + 60)
        #expect(second.pullRequests == first.pullRequests)
        #expect(
            second.accounts.map(\.limits) == [
                Snapshot.Reading(value: [Self.claudeWeek], readAt: Sample.now + 60, askedAt: Sample.now + 60)
            ])
    }

    @Test func claudeAccountsComeBeforeCodexAccounts() async throws {
        let snapshot = await Snapshot.empty.refreshed(
            .limits, github: nil, accounts: [Self.codexWork, Self.codexPersonal, Self.claudeWork],
            tools: [.claude: try claude(), .codex: try codex()], now: Sample.now)
        #expect(snapshot.accounts.map(\.account) == [Self.claudeWork, Self.codexWork, Self.codexPersonal])
        #expect(
            snapshot.accounts.map(\.limits.value) == [
                [Self.claudeWeek], [Self.codexWorkFiveHours], [Self.codexFiveHours],
            ])
        #expect(snapshot.accounts.map(\.limits.trouble) == [nil, nil, nil])
    }

    @Test func aRemovedAccountGoesAndANewOneComesEmpty() async throws {
        let first = await Snapshot.empty.refreshed(
            .limits, github: nil, accounts: [Self.claudeWork, Self.codexPersonal],
            tools: [.claude: try claude(), .codex: try codex()], now: Sample.now)
        let kept = try #require(first.accounts.first)
        let second = await first.refreshed(
            .pullRequests, github: nil, accounts: [Self.claudeWork, Self.codexWork], tools: [:], now: Sample.now + 60)
        #expect(kept.limits.value == [Self.claudeWeek])
        #expect(
            second.accounts == [
                kept,
                Snapshot.AccountLimits(account: Self.codexWork, limits: Snapshot.Reading(value: [])),
            ])
    }

    @Test func aToolThatIsNotThereIsMissing() async throws {
        let snapshot = await Snapshot.empty.refreshed(
            .limits, github: nil, accounts: [Self.claudeWork], tools: [.codex: try codex()], now: Sample.now)
        #expect(
            snapshot.accounts.map(\.limits) == [
                Snapshot.Reading(
                    value: [], askedAt: Sample.now, trouble: .toolMissing, detail: "Claude Code was not found.")
            ]
        )
    }

    @Test func aSignedOutProfileKeepsItsLastLimits() async throws {
        let first = await Snapshot.empty.refreshed(
            .limits, github: nil, accounts: [Self.claudeWork], tools: [.claude: try claude()], now: Sample.now)
        let second = await first.refreshed(
            .limits, github: nil, accounts: [Self.claudeWork],
            tools: [.claude: try claude(signedIn: false, percent: 90)], now: Sample.now + 300)
        #expect(
            second.accounts.map(\.limits) == [
                Snapshot.Reading(
                    value: [Self.claudeWeek], readAt: Sample.now, askedAt: Sample.now + 300, trouble: .signedOut,
                    detail: "Signed out.")
            ])
    }

    @Test func aHungToolFailsAloneWithinItsTimeout() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let snapshot = await Snapshot.empty.refreshed(
            .all, github: github(GitHubExchange(Self.lists)), accounts: [Self.claudeWork, Self.codexPersonal],
            tools: [.claude: try FakeTool.script(named: "claude", "sleep 30"), .codex: try codex()],
            now: Sample.now, toolTimeout: .milliseconds(300))
        #expect(clock.now - started < .seconds(3))
        #expect(snapshot.pullRequests.readAt == Sample.now)
        #expect(snapshot.pullRequests.value.mine.count == 2)
        #expect(
            snapshot.accounts.map(\.limits) == [
                Snapshot.Reading(
                    value: [], askedAt: Sample.now, trouble: .failed, detail: "Claude Code did not answer in time."),
                Snapshot.Reading(value: [Self.codexFiveHours], readAt: Sample.now, askedAt: Sample.now),
            ])
    }

    @Test(arguments: detailCases) func eachFailureIsSaidInAPlainSentence(
        error: any Error, tool: Tool?, sentence: String
    ) {
        #expect(Snapshot.detail(of: error, tool: tool) == sentence)
    }

    @Test func aLongToolOutputIsCutTo300Characters() async throws {
        let output = String(repeating: "x", count: 400)
        let tool = try FakeTool.script(
            named: "claude",
            """
            case "$*" in
              "auth status") echo '{"loggedIn": true}' ;;
              *) echo \(output) >&2; exit 3 ;;
            esac
            """
        )
        let snapshot = await Snapshot.empty.refreshed(
            .limits, github: nil, accounts: [Self.claudeWork], tools: [.claude: tool], now: Sample.now)
        #expect(snapshot.accounts.map(\.limits.trouble) == [.failed])
        #expect(snapshot.accounts.map(\.limits.detail) == [String(repeating: "x", count: 300)])
    }

    @Test(arguments: dueCases)
    func whatIsDue(
        lists: PullRequestLists, pullRequestsAskedAt: Date?, trouble: Snapshot.Trouble?, limitsAskedAt: [Date?],
        due: Snapshot.Parts
    ) {
        var snapshot = Snapshot.empty
        snapshot.pullRequests = Snapshot.Reading(value: lists, askedAt: pullRequestsAskedAt, trouble: trouble)
        snapshot.accounts = limitsAskedAt.map { askedAt in
            Snapshot.AccountLimits(
                account: Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil),
                limits: Snapshot.Reading(value: [], askedAt: askedAt))
        }
        #expect(snapshot.due(at: Sample.now) == due)
    }

    @Test func theFullestLimitIsTheMostUsedOfAnyAccount() {
        var snapshot = Snapshot.empty
        #expect(snapshot.fullestLimit == nil)
        snapshot.accounts = [
            Snapshot.AccountLimits(
                account: Self.claudeWork,
                limits: Snapshot.Reading(
                    value: [UsageLimit(window: .fiveHours, used: 0.41), UsageLimit(window: .week, used: 0.91)])),
            Snapshot.AccountLimits(
                account: Self.codexPersonal, limits: Snapshot.Reading(value: [UsageLimit(window: .week, used: 0.30)])),
        ]
        #expect(snapshot.fullestLimit == UsageLimit(window: .week, used: 0.91))
    }

    static let statuses: [(readSecondsAgo: TimeInterval?, isRefreshing: Bool, isOffline: Bool, status: String)] = [
        (59, false, false, "Updated just now"), (60, false, false, "Updated 1m ago"),
        (840, false, false, "Updated 14m ago"), (840, false, true, "Offline. Updated 14m ago"),
        (nil, false, false, ""), (nil, false, true, "Offline."), (840, true, true, "Updating…"),
    ]

    @Test(arguments: statuses) func theFooterSaysWhenThePullRequestsWereRead(
        readSecondsAgo: TimeInterval?, isRefreshing: Bool, isOffline: Bool, status: String
    ) {
        var snapshot = Snapshot.empty
        snapshot.pullRequests.readAt = readSecondsAgo.map { Sample.now - $0 }
        #expect(snapshot.status(at: Sample.now, isRefreshing: isRefreshing, isOffline: isOffline) == status)
    }
}
