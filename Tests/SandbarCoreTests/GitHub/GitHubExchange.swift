import Foundation
import SandbarCore
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

actor GitHubExchange {
    struct Sent: Decodable {
        var query: String
        var variables: [String: String]
    }

    private(set) var requests: [URLRequest] = []
    private var answers: [(status: Int, body: String)]

    init(_ answers: [(status: Int, body: String)]) {
        self.answers = answers
    }

    init(_ bodies: String...) {
        answers = bodies.map { (200, $0) }
    }

    nonisolated var send: GitHubClient.Send {
        { request in try await self.answer(request) }
    }

    func sent() throws -> [Sent] {
        try requests.map { try JSONDecoder().decode(Sent.self, from: try #require($0.httpBody)) }
    }

    func form(_ index: Int) throws -> [String: String] {
        let body = String(decoding: try #require(requests[index].httpBody), as: UTF8.self)
        let items = try #require(URLComponents(string: "?\(body)")?.queryItems)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = try #require(answers.first, "an unexpected request")
        answers.removeFirst()
        let address = try #require(request.url)
        let response = try #require(
            HTTPURLResponse(url: address, statusCode: status, httpVersion: nil, headerFields: nil))
        return (Data(body.utf8), response)
    }
}

enum GitHubAnswer {
    static func node(
        _ number: Int, title: String? = "Show the delivery date on the order summary", rollup: String? = "SUCCESS",
        reviewDecision: String? = nil, reviews: String = "[]", stack: String = "null", stackEntry: String = "null",
        author: String = #"{"login": "kd", "avatarUrl": "https://avatars.githubusercontent.com/u/1001?v=4"}"#
    ) -> String {
        let titleField = title.map { #""title": "\#($0)","# } ?? ""
        return """
            {"id": "PR_\(number)", "number": \(number), \(titleField)
             "url": "https://github.com/acme/storefront/pull/\(number)", "isDraft": false,
             "createdAt": "2026-11-11T18:00:00Z", "updatedAt": "2026-11-11T18:00:00Z",
             "author": \(author),
             "repository": {"nameWithOwner": "acme/storefront"},
             "baseRefName": "master", "headRefName": "change-\(number)",
             "reviewDecision": \(quoted(reviewDecision)),
             "latestOpinionatedReviews": {"nodes": \(reviews)},
             "isInMergeQueue": false, "stack": \(stack), "stackEntry": \(stackEntry),
             "commits": {"nodes": [{"commit": {"statusCheckRollup": \(rollup.map { #"{"state": "\#($0)"}"# } ?? "null")}}]}}
            """
    }

    static func list(
        mine: [String], mineCursor: String? = nil, reviewRequests: [String]? = [], errors: String? = nil
    ) -> String {
        func search(_ nodes: [String], cursor: String?) -> String {
            """
            {"pageInfo": {"hasNextPage": \(cursor != nil), "endCursor": \(quoted(cursor))},
             "nodes": [\(nodes.joined(separator: ",\n"))]}
            """
        }
        let reviewSearch = reviewRequests.map { #", "reviewRequests": \#(search($0, cursor: nil))"# } ?? ""
        let errorsField = errors.map { #", "errors": \#($0)"# } ?? ""
        return #"{"data": {"mine": \#(search(mine, cursor: mineCursor))\#(reviewSearch)}\#(errorsField)}"#
    }

    static func details(_ checks: [String]..., totalCount: Int? = nil) -> String {
        let nodes = checks.enumerated().map { index, contexts in
            """
            "n\(index)": {"commits": {"nodes": [{"commit": {"statusCheckRollup": {"contexts": {
              "totalCount": \(totalCount ?? contexts.count), "nodes": [\(contexts.joined(separator: ",\n"))]}}}}]}}
            """
        }
        return #"{"data": {\#(nodes.joined(separator: ",\n"))}}"#
    }

    static func checkRun(_ name: String, status: String = "COMPLETED", conclusion: String?) -> String {
        """
        {"__typename": "CheckRun", "name": "\(name)", "status": "\(status)", "conclusion": \(quoted(conclusion)),
         "startedAt": "2026-11-12T17:00:00Z", "isRequired": true}
        """
    }

    static func status(_ context: String, state: String) -> String {
        """
        {"__typename": "StatusContext", "context": "\(context)", "state": "\(state)",
         "createdAt": "2026-11-12T17:00:00Z", "isRequired": true}
        """
    }

    private static func quoted(_ text: String?) -> String {
        text.map { "\"\($0)\"" } ?? "null"
    }
}
