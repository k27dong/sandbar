import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

package enum GitHubError: Error, Equatable {
    case signedOut
    case offline
    case rejected(status: Int, body: String)
    case notUnderstood(String)
}

package struct PullRequestLists: Codable, Equatable, Sendable {
    package var mine: [PullRequest]
    package var reviewRequests: [PullRequest]
    package var hiddenOrganizations: [String]

    package init(mine: [PullRequest], reviewRequests: [PullRequest], hiddenOrganizations: [String]) {
        self.mine = mine
        self.reviewRequests = reviewRequests
        self.hiddenOrganizations = hiddenOrganizations
    }
}

package struct GitHubClient: Sendable {
    package typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    package static let urlSession: Send = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }

    private static let address = URL(string: "https://api.github.com/graphql")!
    private static let pagesPerSearch = 10  // GitHub's search gives at most 1,000 results
    private static let singleSignOnOrganization = "an organization that requires single sign-on"
    private static let restrictingOrganization = "an organization that restricts access"

    private let token: @Sendable () async throws -> String
    private let send: Send

    package init(token: @escaping @Sendable () async throws -> String, send: @escaping Send = GitHubClient.urlSession) {
        self.token = token
        self.send = send
    }

    package func pullRequests() async throws -> PullRequestLists {
        var lists = PullRequestLists(mine: [], reviewRequests: [], hiddenOrganizations: [])
        var read: [PullRequestQuery.Search: Set<String>] = [:]
        var needDetails: [PullRequestQuery.Summary] = []
        var sent: [PullRequestQuery.Search: [String?]] = [:]
        var pages: [PullRequestQuery.Search: String?] = [.mine: nil, .reviewRequests: nil]
        while !pages.isEmpty {
            let answer = try await ask(try PullRequestQuery.listBody(pages))
            let page = try PullRequestQuery.readList(answer, asked: Set(pages.keys))
            for (search, cursor) in pages { sent[search, default: []].append(cursor) }
            for (search, found) in page.found {
                for pullRequest in found where read[search, default: []].insert(pullRequest.id).inserted {
                    lists[keyPath: search.list].append(pullRequest)
                }
            }
            for summary in page.needDetails where !needDetails.contains(where: { $0.id == summary.id }) {
                needDetails.append(summary)
            }
            for name in page.hiddenOrganizations where !lists.hiddenOrganizations.contains(name) {
                lists.hiddenOrganizations.append(name)
            }
            for (search, cursor) in page.cursors {
                let earlier = sent[search] ?? []
                guard !earlier.contains(cursor) else {
                    throw GitHubError.notUnderstood("the \(search.rawValue) search gave the cursor \(cursor) twice")
                }
                guard earlier.count < Self.pagesPerSearch else {
                    throw GitHubError.notUnderstood(
                        "the \(search.rawValue) search has more than \(Self.pagesPerSearch) pages")
                }
            }
            pages = page.cursors.mapValues { $0 }
        }
        guard !needDetails.isEmpty else { return lists }

        let checks = try PullRequestQuery.readDetails(
            try await ask(try PullRequestQuery.detailsBody(needDetails.map(\.id))), needing: needDetails)
        let withDetails = { (pullRequest: PullRequest) in
            var pullRequest = pullRequest
            pullRequest.checks = checks[pullRequest.id] ?? pullRequest.checks
            return pullRequest
        }
        lists.mine = lists.mine.map(withDetails)
        lists.reviewRequests = lists.reviewRequests.map(withDetails)
        return lists
    }

    package func viewer() async throws -> String {
        let answer = try await ask(try Self.body("query { viewer { login } }", variables: [:]))
        let viewer = try Self.content(of: answer).data["viewer"]
        guard let login = (viewer as? [String: Any])?["login"] as? String else {
            throw GitHubError.notUnderstood(Self.excerpt(answer))
        }
        return login
    }

    private func ask(_ body: Data) async throws -> Data {
        var request = URLRequest(url: Self.address)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("bearer \(try await token())", forHTTPHeaderField: "Authorization")
        return try await Self.answer(to: request, send: send)
    }

    static func answer(to request: URLRequest, send: Send) async throws -> Data {
        var request = request
        request.setValue("Sandbar", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await send(request)
        } catch is URLError {
            throw GitHubError.offline
        }
        switch response.statusCode {
        case 200: return data
        case 401: throw GitHubError.signedOut
        default:
            throw GitHubError.rejected(
                status: response.statusCode, body: String(String(decoding: data, as: UTF8.self).prefix(500)))
        }
    }

    static func body(_ query: String, variables: [String: String]) throws -> Data {
        try JSONEncoder().encode(Body(query: query, variables: variables))
    }

    static func content(of answer: Data) throws -> (data: [String: Any], hiddenOrganizations: [String]) {
        let root: [String: Any]?
        do {
            root = try JSONSerialization.jsonObject(with: answer) as? [String: Any]
        } catch {
            throw GitHubError.notUnderstood(excerpt(answer))
        }
        guard let root else { throw GitHubError.notUnderstood(excerpt(answer)) }
        let problems = try root["errors"].map { try decoded([Problem].self, from: $0) } ?? []
        guard let data = root["data"] as? [String: Any], problems.allSatisfy({ $0.type == "FORBIDDEN" }) else {
            let messages = problems.map(\.message).joined(separator: "\n")
            throw GitHubError.notUnderstood(messages.isEmpty ? excerpt(answer) : String(messages.prefix(2_000)))
        }
        let hiddenOrganizations = problems.map { problem in
            let restricted = #/the `(?<name>[^`]+)` organization has enabled OAuth App access restrictions/#
            if let match = problem.message.firstMatch(of: restricted) { return String(match.name) }
            return problem.message.contains("SAML enforcement") ? singleSignOnOrganization : restrictingOrganization
        }
        return (data, hiddenOrganizations)
    }

    static func decoded<Value: Decodable>(_ type: Value.Type, from value: Any) throws -> Value {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch is DecodingError {
            throw GitHubError.notUnderstood(excerpt(data))
        }
    }

    static func excerpt(_ data: Data) -> String {
        String(String(decoding: data, as: UTF8.self).prefix(2_000))
    }

    private struct Body: Encodable {
        var query: String
        var variables: [String: String]
    }

    private struct Problem: Decodable {
        var type: String?
        var message: String
    }
}
