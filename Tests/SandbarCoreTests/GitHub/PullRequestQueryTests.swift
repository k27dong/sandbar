import Foundation
import SandbarCore
import Testing

struct PullRequestQueryTests {
    static let everyField = """
        {"data": {
          "mine": {"pageInfo": {"hasNextPage": false, "endCursor": "Y3Vyc29yOjE="}, "nodes": [{
            "id": "PR_kwDOAcme41250",
            "number": 41250,
            "title": "Show the delivery date on the order summary",
            "url": "https://github.com/acme/storefront/pull/41250",
            "isDraft": true,
            "createdAt": "2026-11-11T18:00:00Z",
            "updatedAt": "2026-11-12T17:00:00Z",
            "author": {"login": "kd", "avatarUrl": "https://avatars.githubusercontent.com/u/1001?v=4"},
            "repository": {"nameWithOwner": "acme/storefront"},
            "baseRefName": "master",
            "headRefName": "delivery-date",
            "reviewDecision": "CHANGES_REQUESTED",
            "latestOpinionatedReviews": {"nodes": [
              {"state": "CHANGES_REQUESTED", "submittedAt": "2026-11-12T16:00:00Z", "author": {"login": "mchen"}}]},
            "isInMergeQueue": false,
            "stack": null,
            "stackEntry": null,
            "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}]}
          }]},
          "reviewRequests": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": []}
        }}
        """
    static let reviewStates = """
        [{"state": "APPROVED", "submittedAt": "2026-11-12T15:00:00Z", "author": {"login": "mchen"}},
         {"state": "CHANGES_REQUESTED", "submittedAt": "2026-11-12T16:00:00Z", "author": {"login": "priya"}},
         {"state": "COMMENTED", "submittedAt": "2026-11-12T17:00:00Z", "author": {"login": "dana"}}]
        """
    static let oauthRestriction = """
        [{"type": "FORBIDDEN", "path": ["mine", "nodes", 0], "locations": [{"line": 2, "column": 3}],
          "message": "Although you appear to have the correct authorization credentials, the `acme` organization \
        has enabled OAuth App access restrictions, meaning that data access to third-parties is limited."}]
        """
    static let summariesNeedingDetails = ["FAILURE", "PENDING"]
    static let decisionCases: [(decision: String?, verdict: PullRequest.Verdict?)] = [
        ("APPROVED", .approved), ("CHANGES_REQUESTED", .changesRequested), ("REVIEW_REQUIRED", nil), (nil, nil),
    ]
    static let checkTable: [(check: String, verdict: Checks.Verdict)] = [
        (GitHubAnswer.checkRun("build", status: "QUEUED", conclusion: nil), .running),
        (GitHubAnswer.checkRun("build", status: "IN_PROGRESS", conclusion: nil), .running),
        (GitHubAnswer.checkRun("build", conclusion: "SUCCESS"), .passed),
        (GitHubAnswer.checkRun("build", conclusion: "NEUTRAL"), .passed),
        (GitHubAnswer.checkRun("build", conclusion: "SKIPPED"), .passed),
        (GitHubAnswer.checkRun("build", conclusion: "FAILURE"), .failed),
        (GitHubAnswer.checkRun("build", conclusion: "CANCELLED"), .failed),
        (GitHubAnswer.checkRun("build", conclusion: "TIMED_OUT"), .failed),
        (GitHubAnswer.checkRun("build", conclusion: "ACTION_REQUIRED"), .failed),
        (GitHubAnswer.status("build", state: "SUCCESS"), .passed),
        (GitHubAnswer.status("build", state: "PENDING"), .running),
        (GitHubAnswer.status("build", state: "EXPECTED"), .running),
        (GitHubAnswer.status("build", state: "FAILURE"), .failed),
        (GitHubAnswer.status("build", state: "ERROR"), .failed),
    ]

    func read(_ answers: String...) async throws -> (lists: PullRequestLists, sent: [GitHubExchange.Sent]) {
        let exchange = GitHubExchange(answers.map { (200, $0) })
        let lists = try await GitHubClient(token: { "T" }, send: exchange.send).pullRequests()
        return (lists, try await exchange.sent())
    }

    @Test func everyFieldMaps() async throws {
        let expected = PullRequest(
            id: "PR_kwDOAcme41250",
            number: 41250,
            title: "Show the delivery date on the order summary",
            url: URL(string: "https://github.com/acme/storefront/pull/41250")!,
            repository: "acme/storefront",
            baseBranch: "master",
            headBranch: "delivery-date",
            author: PullRequest.Author(
                login: "kd", picture: URL(string: "https://avatars.githubusercontent.com/u/1001?v=4")),
            createdAt: Sample.now - 86_400,
            updatedAt: Sample.now - 3_600,
            isDraft: true,
            isInMergeQueue: false,
            decision: .changesRequested,
            reviews: [PullRequest.Review(author: "mchen", verdict: .changesRequested, submittedAt: Sample.now - 7_200)],
            checks: Checks(verdict: .passed),
            stack: nil
        )
        let lists = try await read(Self.everyField).lists
        #expect(lists == PullRequestLists(mine: [expected], reviewRequests: [], hiddenOrganizations: []))
    }

    @Test func noSummaryHasNoVerdict() async throws {
        let (lists, sent) = try await read(GitHubAnswer.list(mine: [GitHubAnswer.node(1, rollup: nil)]))
        #expect(lists.mine.map(\.checks) == [Checks(verdict: nil)])
        #expect(sent.count == 1)
    }

    @Test func successPassesWithoutDetails() async throws {
        let (lists, sent) = try await read(GitHubAnswer.list(mine: [GitHubAnswer.node(1, rollup: "SUCCESS")]))
        #expect(lists.mine.map(\.checks) == [Checks(verdict: .passed)])
        #expect(sent.count == 1)
    }

    @Test(arguments: summariesNeedingDetails) func summaryAsksForDetails(summary: String) async throws {
        let (lists, sent) = try await read(
            GitHubAnswer.list(mine: [GitHubAnswer.node(1, rollup: summary)]),
            GitHubAnswer.details([GitHubAnswer.checkRun("test", conclusion: "FAILURE")])
        )
        #expect(sent.count == 2)
        #expect(sent.last?.variables == ["n0": "PR_1"])
        #expect(lists.mine.map(\.checks) == [Checks(verdict: .failed, failed: ["test"])])
    }

    @Test(arguments: decisionCases) func reviewDecisionGivesVerdict(
        decision: String?, verdict: PullRequest.Verdict?
    ) async throws {
        let lists = try await read(GitHubAnswer.list(mine: [GitHubAnswer.node(1, reviewDecision: decision)])).lists
        #expect(lists.mine.map(\.decision) == [verdict])
    }

    @Test func onlyApprovalsAndChangeRequestsAreKept() async throws {
        let lists = try await read(GitHubAnswer.list(mine: [GitHubAnswer.node(1, reviews: Self.reviewStates)])).lists
        #expect(
            lists.mine.map(\.reviews) == [
                [
                    PullRequest.Review(author: "mchen", verdict: .approved, submittedAt: Sample.now - 10_800),
                    PullRequest.Review(author: "priya", verdict: .changesRequested, submittedAt: Sample.now - 7_200),
                ]
            ])
    }

    @Test func stackGivesItsPlace() async throws {
        let node = GitHubAnswer.node(1, stack: #"{"number": 7}"#, stackEntry: #"{"position": 2}"#)
        let lists = try await read(GitHubAnswer.list(mine: [node])).lists
        #expect(lists.mine.map(\.stack) == [PullRequest.StackPlace(number: 7, position: 2)])
    }

    @Test func emptyNodeIsSkipped() async throws {
        let lists = try await read(GitHubAnswer.list(mine: ["{}", GitHubAnswer.node(2)])).lists
        #expect(lists.mine.map(\.number) == [2])
    }

    @Test func nodeWithoutTitleIsNotUnderstood() async throws {
        let error = await #expect(throws: GitHubError.self) {
            try await read(GitHubAnswer.list(mine: [GitHubAnswer.node(41250, title: nil)]))
        }
        guard case .notUnderstood(let received) = error else {
            Issue.record("expected notUnderstood, got \(String(describing: error))")
            return
        }
        #expect(received.contains("PR_41250"))
    }

    @Test func errorsWithoutDataAreNotUnderstood() async throws {
        let answer = #"{"errors": [{"message": "Something went wrong while executing your query."}]}"#
        await #expect(throws: GitHubError.notUnderstood("Something went wrong while executing your query.")) {
            try await read(answer)
        }
    }

    @Test func organizationWithAppRestrictionsIsHidden() async throws {
        let answer = GitHubAnswer.list(mine: ["null", GitHubAnswer.node(2)], errors: Self.oauthRestriction)
        let lists = try await read(answer).lists
        #expect(lists.hiddenOrganizations == ["acme"])
        #expect(lists.mine.map(\.number) == [2])
    }

    @Test(arguments: checkTable) func checkOutcome(check: String, verdict: Checks.Verdict) async throws {
        let lists = try await read(
            GitHubAnswer.list(mine: [GitHubAnswer.node(1, rollup: "PENDING")]),
            GitHubAnswer.details([check])
        ).lists
        #expect(lists.mine.map(\.checks.verdict) == [verdict])
    }
}
