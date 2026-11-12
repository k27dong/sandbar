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
    package var hiddenOrganizations: [String]  // organizations GitHub says this sign-in may not see

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

    private let token: @Sendable () async throws -> String
    private let send: Send

    package init(token: @escaping @Sendable () async throws -> String, send: @escaping Send = GitHubClient.urlSession) {
        self.token = token
        self.send = send
    }

    package func pullRequests() async throws -> PullRequestLists {
        var lists = PullRequestLists(mine: [], reviewRequests: [], hiddenOrganizations: [])
        var needDetails: [String] = []
        var pages: [PullRequestQuery.Search: String?] = [.mine: nil, .reviewRequests: nil]
        while !pages.isEmpty {
            let page = try PullRequestQuery.readList(try await ask(try PullRequestQuery.listBody(pages)))
            lists.mine += page.found[.mine] ?? []
            lists.reviewRequests += page.found[.reviewRequests] ?? []
            needDetails += page.needDetails
            for name in page.hiddenOrganizations where !lists.hiddenOrganizations.contains(name) {
                lists.hiddenOrganizations.append(name)
            }
            pages = page.cursors.mapValues { $0 }
        }
        guard !needDetails.isEmpty else { return lists }

        let checks = try PullRequestQuery.readDetails(
            try await ask(try PullRequestQuery.detailsBody(needDetails)), ids: needDetails)
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
        let answer = try await ask(try PullRequestQuery.body("query { viewer { login } }", variables: [:]))
        let viewer = try PullRequestQuery.content(of: answer).data["viewer"]
        guard let login = (viewer as? [String: Any])?["login"] as? String else {
            throw GitHubError.notUnderstood(PullRequestQuery.excerpt(answer))
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
}
