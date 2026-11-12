import Foundation
import SandbarCore
import Testing

struct PullRequestTests {
    static let passed = Checks(verdict: .passed)
    static let running = Checks(verdict: .running)
    static let failed = Checks(verdict: .failed, failed: ["test"])
    static let approval = PullRequest.Review(author: "mchen", verdict: .approved, submittedAt: Sample.now - 3_600)
    static let changeRequest = PullRequest.Review(
        author: "priya",
        verdict: .changesRequested,
        submittedAt: Sample.now - 1_800
    )
    static let placeCases: [(pullRequest: PullRequest, place: Int)] = [
        (.sample(1, isInMergeQueue: true, checks: passed), 1),
        (.sample(2, decision: .approved, checks: passed), 2),
        (.sample(3, decision: .approved, checks: running), 3),
        (.sample(4, decision: .approved, checks: failed), 4),
        (.sample(5, checks: passed), 5),
        (.sample(6, checks: running), 6),
        (.sample(7, checks: failed), 7),
        (.sample(8, decision: .changesRequested, checks: passed), 8),
        (.sample(9, isDraft: true, checks: failed), 9),
        (.sample(10, decision: .approved), 2),
        (.sample(11), 5),
        (.sample(12, isInMergeQueue: true, checks: failed), 1),
        (.sample(13, decision: .changesRequested, checks: failed), 8),
        (.sample(14, isDraft: true, checks: passed), 9),
    ]

    @Test func mergeQueueWinsOverDraftAndApproval() {
        #expect(PullRequest.sample(1, isDraft: true, isInMergeQueue: true).state == .merging)
        #expect(PullRequest.sample(1, isInMergeQueue: true, decision: .approved).state == .merging)
    }

    @Test func draftWinsOverApprovingDecision() {
        #expect(PullRequest.sample(1, isDraft: true, decision: .approved).state == .draft)
    }

    @Test func decisionSetsTheState() {
        #expect(PullRequest.sample(1, decision: .changesRequested).state == .changesRequested)
        #expect(PullRequest.sample(1, decision: .approved).state == .approved)
        #expect(PullRequest.sample(1).state == .open)
    }

    @Test func oneApprovalIsEnoughWithoutADecision() {
        let pullRequest = PullRequest.sample(1, reviews: [Self.approval])
        #expect(pullRequest.verdict == .approved)
        #expect(pullRequest.state == .approved)
    }

    @Test func anyChangeRequestWinsWithoutADecision() {
        let pullRequest = PullRequest.sample(1, reviews: [Self.approval, Self.changeRequest])
        #expect(pullRequest.verdict == .changesRequested)
        #expect(pullRequest.state == .changesRequested)
    }

    @Test func repositoryNameDropsTheOwner() {
        #expect(PullRequest.sample(1, repository: "acme/api").repositoryName == "api")
    }

    @Test(arguments: placeCases) func place(pullRequest: PullRequest, place: Int) {
        #expect(pullRequest.place == place)
    }
}
