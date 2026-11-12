import Foundation
import SandbarCore
import Testing

struct StackTests {
    static func githubStack(positions: [Int]) -> [PullRequest] {
        positions.map { .sample(40 + $0, stack: PullRequest.StackPlace(number: 7, position: $0)) }
    }

    static func numbers(_ stacks: [Stack]) -> [[Int]] {
        stacks.map { $0.pullRequests.map(\.number) }
    }

    @Test func githubStackIsOrderedByPosition() {
        let grouped = Stack.grouping(Self.githubStack(positions: [2, 1, 3]))
        #expect(Self.numbers(grouped.stacks) == [[41, 42, 43]])
        #expect(grouped.stacks.map(\.id) == ["acme/storefront#7"])
        #expect(grouped.singles.isEmpty)
    }

    @Test func githubStackKeepsItsOrderAcrossAMergedMember() {
        let grouped = Stack.grouping(Self.githubStack(positions: [5, 1, 4, 2]))
        #expect(Self.numbers(grouped.stacks) == [[41, 42, 44, 45]])
    }

    @Test func onlyOpenMemberOfAGithubStackIsASingle() {
        let grouped = Stack.grouping(Self.githubStack(positions: [3]))
        #expect(grouped.stacks.isEmpty)
        #expect(grouped.singles.map(\.number) == [43])
    }

    @Test func branchChainComesBackBottomFirst() {
        let bottom = PullRequest.sample(1, baseBranch: "master", headBranch: "cart")
        let middle = PullRequest.sample(2, baseBranch: "cart", headBranch: "cart-totals")
        let top = PullRequest.sample(3, baseBranch: "cart-totals", headBranch: "cart-coupons")
        let single = PullRequest.sample(4, baseBranch: "master", headBranch: "search")
        let grouped = Stack.grouping([top, single, bottom, middle])
        #expect(Self.numbers(grouped.stacks) == [[1, 2, 3]])
        #expect(grouped.stacks.map(\.id) == ["acme/storefront#cart"])
        #expect(grouped.singles.map(\.number) == [4])
    }

    @Test func branchChainsNeverCrossRepositories() {
        let storefront = PullRequest.sample(1, repository: "acme/storefront", headBranch: "shared")
        let api = PullRequest.sample(2, repository: "acme/api", baseBranch: "shared", headBranch: "orders")
        let grouped = Stack.grouping([storefront, api])
        #expect(grouped.stacks.isEmpty)
        #expect(grouped.singles.count == 2)
    }

    @Test func twoOnTheSameBaseBranchAreSingles() {
        let bottom = PullRequest.sample(1, headBranch: "cart")
        let first = PullRequest.sample(2, baseBranch: "cart", headBranch: "cart-totals")
        let second = PullRequest.sample(3, baseBranch: "cart", headBranch: "cart-coupons")
        let grouped = Stack.grouping([bottom, first, second])
        #expect(grouped.stacks.isEmpty)
        #expect(grouped.singles.map(\.number) == [1, 2, 3])
    }

    @Test func loopOfBranchesEnds() {
        let first = PullRequest.sample(1, baseBranch: "cart", headBranch: "search")
        let second = PullRequest.sample(2, baseBranch: "search", headBranch: "cart")
        let grouped = Stack.grouping([first, second])
        let listed = grouped.stacks.flatMap(\.pullRequests) + grouped.singles
        #expect(listed.map(\.number).sorted() == [1, 2])
    }

    @Test func githubStackIsNeverChainedByBranch() {
        let stacked = PullRequest.sample(1, headBranch: "cart", stack: PullRequest.StackPlace(number: 7, position: 1))
        let unstacked = PullRequest.sample(2, baseBranch: "cart", headBranch: "cart-totals")
        let grouped = Stack.grouping([stacked, unstacked])
        #expect(grouped.stacks.isEmpty)
        #expect(grouped.singles.count == 2)
    }

    @Test func foldedStackOfFiveShowsTheFirstTwo() throws {
        let stack = try #require(Stack.grouping(Self.githubStack(positions: [1, 2, 3, 4, 5])).stacks.first)
        #expect(stack.shown(isOpen: false).map(\.number) == [41, 42])
        #expect(stack.shown(isOpen: true).map(\.number) == [41, 42, 43, 44, 45])
    }

    @Test func stackOfThreeShowsAll() throws {
        let stack = try #require(Stack.grouping(Self.githubStack(positions: [1, 2, 3])).stacks.first)
        #expect(stack.shown(isOpen: false).map(\.number) == [41, 42, 43])
    }
}
