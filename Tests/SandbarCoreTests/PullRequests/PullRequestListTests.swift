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

    @Test func lowerNumberBreaksATie() {
        let list = PullRequestList(
            mine: [PullRequest.sample(5), PullRequest.sample(3)],
            reviewRequests: [PullRequest.sample(8, author: "mchen"), PullRequest.sample(6, author: "dana")]
        )
        #expect(list.mine.map(\.lead.number) == [3, 5])
        #expect(list.reviewRequests.map(\.number) == [6, 8])
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

    @Test func aStackWalksAsItIsShownFoldedOrOpenFromEitherEnd() throws {
        let chain: [PullRequest] = [
            .sample(1, headBranch: "a"), .sample(2, baseBranch: "a", headBranch: "b"),
            .sample(3, baseBranch: "b", headBranch: "c"), .sample(4, baseBranch: "c", headBranch: "d"),
        ]
        let list = PullRequestList(mine: chain, reviewRequests: [.sample(9, author: "mchen")])
        guard case .stack(let stack) = try #require(list.mine.first) else {
            Issue.record("the four chained pull requests are one stack")
            return
        }
        let request = PullRequestList.Selection.pullRequest(PullRequest.sample(9).id)
        let rows = { (numbers: [Int]) in
            numbers.map { PullRequestList.Selection.pullRequest(PullRequest.sample($0).id) }
        }

        #expect(
            list.rows(openStacks: [], topFirst: false).map(\.selection) == [request] + rows([1, 2]) + [.fold(stack.id)])
        #expect(
            list.rows(openStacks: [], topFirst: true).map(\.selection) == [request, .fold(stack.id)] + rows([2, 1]))
        #expect(
            list.rows(openStacks: [stack.id], topFirst: true).map(\.selection)
                == [request, .fold(stack.id)] + rows([4, 3, 2, 1]))
    }

    @Test func aStackOfThreeHasNoFoldRow() {
        let chain: [PullRequest] = [
            .sample(1, headBranch: "a"), .sample(2, baseBranch: "a", headBranch: "b"),
            .sample(3, baseBranch: "b", headBranch: "c"),
        ]
        let rows = PullRequestList(mine: chain, reviewRequests: []).rows(openStacks: [], topFirst: false)
        #expect(rows.map(\.selection) == [1, 2, 3].map { .pullRequest(PullRequest.sample($0).id) })
    }

    @Test func theSelectionMovesThroughTheRowsAndStaysAtBothEnds() {
        let rows = PullRequestList(mine: [.sample(1), .sample(2)], reviewRequests: [])
            .rows(openStacks: [], topFirst: true)
        let first = rows[0].selection
        let last = rows[1].selection
        #expect(PullRequestList.selection(after: nil, movedBy: 1, in: rows) == first)
        #expect(PullRequestList.selection(after: nil, movedBy: -1, in: rows) == last)
        #expect(PullRequestList.selection(after: first, movedBy: 1, in: rows) == last)
        #expect(PullRequestList.selection(after: last, movedBy: 1, in: rows) == last)
        #expect(PullRequestList.selection(after: first, movedBy: -1, in: rows) == first)
        #expect(PullRequestList.selection(after: .fold("a stack that is gone"), movedBy: 1, in: rows) == first)
        #expect(PullRequestList.selection(after: nil, movedBy: 1, in: []) == nil)
    }

    @Test func onlyTheChosenRepositoriesAreKept() {
        let lists = PullRequestLists(
            mine: [.sample(1), .sample(2, repository: "acme/api")],
            reviewRequests: [.sample(3, repository: "acme/tools")], hiddenOrganizations: ["acme"])
        #expect(lists.repositories == ["acme/api", "acme/storefront", "acme/tools"])
        #expect(lists.only(in: nil) == lists)
        let chosen = lists.only(in: ["acme/api", "acme/tools"])
        #expect(chosen.mine.map(\.number) == [2])
        #expect(chosen.reviewRequests.map(\.number) == [3])
        #expect(chosen.hiddenOrganizations == ["acme"])
    }
}
