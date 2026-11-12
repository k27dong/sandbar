import Foundation
import SandbarCore
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct GitHubClientTests {
    static let badGateway = "<html><body><h1>502 Bad Gateway</h1></body></html>"
    static let cursor = "Y3Vyc29yOjEwMA=="

    actor Count {
        var value = 0
        func next() -> Int {
            value += 1
            return value
        }
    }

    @Test func requestIsAPostToGraphQLWithTheToken() async throws {
        let exchange = GitHubExchange(GitHubAnswer.list(mine: []))
        _ = try await GitHubClient(token: { "T" }, send: exchange.send).pullRequests()
        let request = try #require(await exchange.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == URL(string: "https://api.github.com/graphql"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "bearer T")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Sandbar")
    }

    @Test func unauthorizedIsSignedOut() async throws {
        let exchange = GitHubExchange([(401, #"{"message": "Bad credentials"}"#)])
        await #expect(throws: GitHubError.signedOut) {
            try await GitHubClient(token: { "T" }, send: exchange.send).pullRequests()
        }
    }

    @Test func noConnectionIsOffline() async throws {
        let client = GitHubClient(token: { "T" }, send: { _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: GitHubError.offline) { try await client.pullRequests() }
    }

    @Test func badGatewayIsRejected() async throws {
        let exchange = GitHubExchange([(502, Self.badGateway)])
        await #expect(throws: GitHubError.rejected(status: 502, body: Self.badGateway)) {
            try await GitHubClient(token: { "T" }, send: exchange.send).pullRequests()
        }
    }

    @Test func rejectedBodyIsCutTo500Characters() async throws {
        let exchange = GitHubExchange([(503, String(repeating: "x", count: 600))])
        await #expect(throws: GitHubError.rejected(status: 503, body: String(repeating: "x", count: 500))) {
            try await GitHubClient(token: { "T" }, send: exchange.send).pullRequests()
        }
    }

    @Test func onlyTheSearchWithMoreAsksForTheNextPage() async throws {
        let exchange = GitHubExchange(
            GitHubAnswer.list(
                mine: (1...100).map { GitHubAnswer.node($0) }, mineCursor: Self.cursor,
                reviewRequests: (901...903).map { GitHubAnswer.node($0) }),
            GitHubAnswer.list(mine: (101...150).map { GitHubAnswer.node($0) }, reviewRequests: nil)
        )
        let lists = try await GitHubClient(token: { "T" }, send: exchange.send).pullRequests()
        #expect(lists.mine.map(\.number) == Array(1...150))
        #expect(lists.reviewRequests.map(\.number) == [901, 902, 903])
        let sent = try await exchange.sent()
        #expect(sent.count == 2)
        #expect(sent.first?.variables["mineAfter"] == nil)
        #expect(sent.last?.variables["mineAfter"] == Self.cursor)
        #expect(sent.last?.query.contains("reviewRequests") == false)
    }

    @Test func exactlyOneFullPageIsOneRequest() async throws {
        let exchange = GitHubExchange(GitHubAnswer.list(mine: (1...100).map { GitHubAnswer.node($0) }))
        let lists = try await GitHubClient(token: { "T" }, send: exchange.send).pullRequests()
        #expect(lists.mine.count == 100)
        #expect(await exchange.requests.count == 1)
    }

    @Test func detailsReplaceTheVerdictOfThoseThatNeedThem() async throws {
        let exchange = GitHubExchange(
            GitHubAnswer.list(
                mine: [
                    GitHubAnswer.node(1, rollup: "SUCCESS"), GitHubAnswer.node(2, rollup: "FAILURE"),
                    GitHubAnswer.node(3, rollup: nil),
                ],
                reviewRequests: [GitHubAnswer.node(4, rollup: "PENDING")]),
            GitHubAnswer.details(
                [GitHubAnswer.checkRun("test", conclusion: "FAILURE")],
                [GitHubAnswer.checkRun("build", conclusion: "SUCCESS")])
        )
        let lists = try await GitHubClient(token: { "T" }, send: exchange.send).pullRequests()
        #expect(try await exchange.sent().last?.variables == ["n0": "PR_2", "n1": "PR_4"])
        #expect(
            lists.mine.map(\.checks) == [
                Checks(verdict: .passed), Checks(verdict: .failed, failed: ["test"]), Checks(verdict: nil),
            ])
        #expect(lists.reviewRequests.map(\.checks) == [Checks(verdict: .passed)])
    }

    @Test func tokenIsAskedForEveryRequest() async throws {
        let exchange = GitHubExchange(
            GitHubAnswer.list(mine: [GitHubAnswer.node(1)], mineCursor: Self.cursor),
            GitHubAnswer.list(mine: [GitHubAnswer.node(2, rollup: "FAILURE")], reviewRequests: nil),
            GitHubAnswer.details([GitHubAnswer.checkRun("test", conclusion: "FAILURE")])
        )
        let count = Count()
        let client = GitHubClient(token: { "T\(await count.next())" }, send: exchange.send)
        _ = try await client.pullRequests()
        #expect(await count.value == 3)
        let tokens = await exchange.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(tokens == ["bearer T1", "bearer T2", "bearer T3"])
    }

    @Test func viewerIsTheSignedInLogin() async throws {
        let exchange = GitHubExchange(#"{"data": {"viewer": {"login": "kd"}}}"#)
        #expect(try await GitHubClient(token: { "T" }, send: exchange.send).viewer() == "kd")
    }
}
