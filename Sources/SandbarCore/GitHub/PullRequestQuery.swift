import Foundation

enum PullRequestQuery {
    enum Search: String, CaseIterable {
        case mine, reviewRequests

        var text: String {
            switch self {
            case .mine: "is:pr is:open author:@me archived:false"
            case .reviewRequests: "is:pr is:open review-requested:@me archived:false"
            }
        }

        var list: WritableKeyPath<PullRequestLists, [PullRequest]> {
            switch self {
            case .mine: \.mine
            case .reviewRequests: \.reviewRequests
            }
        }
    }

    struct Summary {
        var id: String
        var state: String
    }

    struct ListPage {
        var found: [Search: [PullRequest]] = [:]
        var cursors: [Search: String] = [:]
        var needDetails: [Summary] = []
        var hiddenOrganizations: [String]
    }

    private static let deletedAccount = "ghost"
    private static let checksPerPullRequest = 100

    private static let fields = """
        id number title url isDraft createdAt updatedAt author { login avatarUrl } repository { nameWithOwner }
        baseRefName headRefName reviewDecision
        latestOpinionatedReviews(first: 20) { nodes { state submittedAt author { login } } }
        isInMergeQueue stack { number } stackEntry { position }
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        """

    static func listBody(_ pages: [Search: String?]) throws -> Data {
        var declarations: [String] = []
        var searches: [String] = []
        var variables: [String: String] = [:]
        for search in Search.allCases {
            guard let after = pages[search] else { continue }
            let name = search.rawValue
            declarations += ["$\(name): String!", "$\(name)After: String"]
            searches.append(
                """
                \(name): search(query: $\(name), type: ISSUE, first: 100, after: $\(name)After) {
                  pageInfo { hasNextPage endCursor }
                  nodes { ... on PullRequest { \(fields) } }
                }
                """)
            variables[name] = search.text
            variables["\(name)After"] = after
        }
        let query = "query(\(declarations.joined(separator: ", "))) {\n\(searches.joined(separator: "\n"))\n}"
        return try GitHubClient.body(query, variables: variables)
    }

    static func readList(_ answer: Data, asked: Set<Search>) throws -> ListPage {
        let (content, hiddenOrganizations) = try GitHubClient.content(of: answer)
        var page = ListPage(hiddenOrganizations: hiddenOrganizations)
        for search in Search.allCases where asked.contains(search) {
            guard let result = content[search.rawValue] as? [String: Any], let nodes = result["nodes"] as? [Any] else {
                throw GitHubError.notUnderstood(try received(content))
            }
            let pageInfo = try GitHubClient.decoded(PageInfo.self, from: result["pageInfo"] ?? NSNull())
            if pageInfo.hasNextPage {
                guard let cursor = pageInfo.endCursor else { throw GitHubError.notUnderstood(try received(result)) }
                page.cursors[search] = cursor
            }
            var found: [PullRequest] = []
            for node in nodes {
                if node is NSNull || (node as? [String: Any])?.isEmpty == true { continue }  // hidden, or an issue
                let (pullRequest, summary) = try GitHubClient.decoded(Node.self, from: node).pullRequest(node)
                found.append(pullRequest)
                if let summary, summary != "SUCCESS" {
                    page.needDetails.append(Summary(id: pullRequest.id, state: summary))
                }
            }
            page.found[search] = found
        }
        return page
    }

    static func detailsBody(_ ids: [String]) throws -> Data {
        let declarations = ids.indices.map { "$n\($0): ID!" }.joined(separator: ", ")
        let nodes = ids.indices.map { index in
            """
            n\(index): node(id: $n\(index)) { ... on PullRequest {
              commits(last: 1) { nodes { commit { statusCheckRollup {
                contexts(first: \(checksPerPullRequest)) { totalCount nodes {
                __typename
                ... on CheckRun { name status conclusion startedAt isRequired(pullRequestId: $n\(index)) }
                ... on StatusContext { context state createdAt isRequired(pullRequestId: $n\(index)) }
              } } } } } }
            } }
            """
        }
        let variables = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ("n\($0.offset)", $0.element) })
        return try GitHubClient.body(
            "query(\(declarations)) {\n\(nodes.joined(separator: "\n"))\n}", variables: variables)
    }

    static func readDetails(_ answer: Data, needing summaries: [Summary]) throws -> [String: Checks] {
        let content = try GitHubClient.content(of: answer).data
        var checks: [String: Checks] = [:]
        for (index, summary) in summaries.enumerated() {
            let node = content["n\(index)"] ?? NSNull()
            let rollup = try GitHubClient.decoded(DetailNode.self, from: node).commits.nodes.first?.commit
                .statusCheckRollup
            if let rollup, rollup.contexts.totalCount > checksPerPullRequest {  // unseen checks may fail or run
                let failed = ["FAILURE", "ERROR"].contains(summary.state)
                checks[summary.id] = Checks(verdict: failed ? .failed : .running)
                continue
            }
            var runs: [CheckRun] = []
            for context in rollup?.contexts.nodes ?? [] {
                guard let run = context.run else { throw GitHubError.notUnderstood(try received(node)) }
                runs.append(run)
            }
            checks[summary.id] = Checks(counting: runs)
        }
        return checks
    }

    private static func received(_ value: Any) throws -> String {
        GitHubClient.excerpt(
            try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]))
    }

    private struct PageInfo: Decodable {
        var hasNextPage: Bool
        var endCursor: String?
    }

    private struct Nodes<Element: Decodable>: Decodable {
        var nodes: [Element]
    }

    private struct Node: Decodable {
        struct Author: Decodable {
            var login: String
            var avatarUrl: URL
        }
        struct Repository: Decodable { var nameWithOwner: String }
        struct Review: Decodable {
            struct Author: Decodable { var login: String }
            var state: String
            var submittedAt: Date
            var author: Author?
        }
        struct Stack: Decodable { var number: Int }
        struct StackEntry: Decodable { var position: Int }
        struct Commit: Decodable {
            struct Content: Decodable {
                struct Rollup: Decodable { var state: String }
                var statusCheckRollup: Rollup?
            }
            var commit: Content
        }

        var id: String
        var number: Int
        var title: String
        var url: URL
        var isDraft: Bool
        var createdAt: Date
        var updatedAt: Date
        var author: Author?
        var repository: Repository
        var baseRefName: String
        var headRefName: String
        var reviewDecision: String?
        var latestOpinionatedReviews: Nodes<Review>
        var isInMergeQueue: Bool
        var stack: Stack?
        var stackEntry: StackEntry?
        var commits: Nodes<Commit>

        func pullRequest(_ received: Any) throws -> (PullRequest, summary: String?) {
            let decision: PullRequest.Verdict? =
                switch reviewDecision {
                case "APPROVED": .approved
                case "CHANGES_REQUESTED": .changesRequested
                case "REVIEW_REQUIRED", nil: nil
                default: throw GitHubError.notUnderstood(try PullRequestQuery.received(received))
                }
            let reviews = latestOpinionatedReviews.nodes.compactMap { review -> PullRequest.Review? in
                let verdict: PullRequest.Verdict? =
                    switch review.state {
                    case "APPROVED": .approved
                    case "CHANGES_REQUESTED": .changesRequested
                    default: nil
                    }
                return verdict.map {
                    PullRequest.Review(
                        author: review.author?.login ?? PullRequestQuery.deletedAccount, verdict: $0,
                        submittedAt: review.submittedAt)
                }
            }
            var place: PullRequest.StackPlace?
            if let stack, let stackEntry {
                place = PullRequest.StackPlace(number: stack.number, position: stackEntry.position)
            }
            let summary = commits.nodes.first?.commit.statusCheckRollup?.state
            let pullRequest = PullRequest(
                id: id,
                number: number,
                title: title,
                url: url,
                repository: repository.nameWithOwner,
                baseBranch: baseRefName,
                headBranch: headRefName,
                author: PullRequest.Author(
                    login: author?.login ?? PullRequestQuery.deletedAccount, picture: author?.avatarUrl),
                createdAt: createdAt,
                updatedAt: updatedAt,
                isDraft: isDraft,
                isInMergeQueue: isInMergeQueue,
                decision: decision,
                reviews: reviews,
                checks: Checks(verdict: summary == "SUCCESS" ? .passed : nil),  // details replace any other summary
                stack: place
            )
            return (pullRequest, summary)
        }
    }

    private struct DetailNode: Decodable {
        struct Commit: Decodable {
            struct Content: Decodable {
                struct Rollup: Decodable {
                    struct Contexts: Decodable {
                        var totalCount: Int
                        var nodes: [Context]
                    }
                    var contexts: Contexts
                }
                var statusCheckRollup: Rollup?
            }
            var commit: Content
        }

        struct Context: Decodable {
            enum CodingKeys: String, CodingKey {
                case kind = "__typename"
                case name, status, conclusion, startedAt, context, state, createdAt, isRequired
            }
            var kind: String
            var name: String?
            var status: String?
            var conclusion: String?
            var startedAt: Date?
            var context: String?
            var state: String?
            var createdAt: Date?
            var isRequired: Bool

            var run: CheckRun? {
                switch kind {
                case "CheckRun":
                    guard let name, let status else { return nil }
                    let passed = ["SUCCESS", "NEUTRAL", "SKIPPED"].contains(conclusion)
                    let outcome: CheckRun.Outcome = status != "COMPLETED" ? .running : passed ? .passed : .failed
                    return CheckRun(name: name, isRequired: isRequired, outcome: outcome, startedAt: startedAt)
                case "StatusContext":
                    guard let context, let state else { return nil }
                    let outcome: CheckRun.Outcome =
                        switch state {
                        case "SUCCESS": .passed
                        case "PENDING", "EXPECTED": .running
                        default: .failed
                        }
                    return CheckRun(name: context, isRequired: isRequired, outcome: outcome, startedAt: createdAt)
                default:
                    return nil
                }
            }
        }

        var commits: Nodes<Commit>
    }
}
