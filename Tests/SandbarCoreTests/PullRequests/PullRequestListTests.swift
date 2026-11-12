import Foundation
import SandbarCore
import Testing

struct PullRequestListTests {
    static let onePerPlace: [PullRequest] = [
        .sample(7, checks: Checks(verdict: .failed, failed: ["lint"])),
        .sample(2, decision: .approved, checks: Checks(verdict: .passed)),
        .sample(9, isDraft: true),
        .sample(5, checks: Checks(verdict: .passed)),
        .sample(1, isInMergeQueue: true),
        .sample(8, decision: .changesRequested),
        .sample(4, decision: .approved, checks: Checks(verdict: .failed, failed: ["lint"])),
        .sample(6, checks: Checks(verdict: .running)),
        .sample(3, decision: .approved, checks: Checks(verdict: .running)),
    ]

    @Test func singlesFollowThePlaceOrder() {
        let list = PullRequestList(mine: Self.onePerPlace, reviewRequests: [])
        #expect(list.mine.map(\.lead.place) == Array(1...9))
        #expect(list.mine.map(\.lead.number) == Array(1...9))
    }

    @Test func oldestComesFirstInTheSamePlace() {
        let newer = PullRequest.sample(1, createdAt: Sample.now - 2 * 86_400)
        let older = PullRequest.sample(2, createdAt: Sample.now - 5 * 86_400)
        let list = PullRequestList(mine: [newer, older], reviewRequests: [])
        #expect(list.mine.map(\.lead.number) == [2, 1])
    }

    @Test func stackSitsWhereItsBottomBelongs() {
        let bottom = PullRequest.sample(1, headBranch: "cart", decision: .approved, checks: Checks(verdict: .passed))
        let top = PullRequest.sample(2, baseBranch: "cart", headBranch: "cart-totals", isDraft: true)
        let single = PullRequest.sample(3, createdAt: Sample.now - 10 * 86_400, checks: Checks(verdict: .passed))
        let list = PullRequestList(mine: [single, top, bottom], reviewRequests: [])
        #expect(list.mine.map(\.id) == ["acme/storefront#cart", single.id])
    }

    @Test func reviewRequestsComeLongestOpenFirst() {
        let recent = PullRequest.sample(1, author: "mchen", createdAt: Sample.now - 3_600)
        let oldest = PullRequest.sample(2, author: "priya", createdAt: Sample.now - 9 * 86_400)
        let older = PullRequest.sample(3, author: "dana", createdAt: Sample.now - 2 * 86_400)
        let list = PullRequestList(mine: [], reviewRequests: [recent, oldest, older])
        #expect(list.reviewRequests.map(\.number) == [2, 3, 1])
    }

    @Test func openCountIncludesStackMembersAndNotReviewRequests() {
        let mine = [
            PullRequest.sample(1),
            PullRequest.sample(2),
            PullRequest.sample(3, headBranch: "cart"),
            PullRequest.sample(4, baseBranch: "cart", headBranch: "cart-totals"),
            PullRequest.sample(5, baseBranch: "cart-totals", headBranch: "cart-coupons"),
        ]
        let list = PullRequestList(mine: mine, reviewRequests: [PullRequest.sample(6, author: "mchen")])
        #expect(list.mine.count == 3)
        #expect(list.openCount == 5)
    }
}
