import Foundation

package struct PullRequest: Codable, Hashable, Identifiable, Sendable {
    package enum State: Sendable { case merging, draft, changesRequested, approved, open }
    package enum Verdict: String, Codable, Sendable { case approved, changesRequested }

    package struct Review: Codable, Hashable, Sendable {
        package var author: String
        package var verdict: Verdict
        package var submittedAt: Date

        package init(author: String, verdict: Verdict, submittedAt: Date) {
            self.author = author
            self.verdict = verdict
            self.submittedAt = submittedAt
        }
    }

    package struct Author: Codable, Hashable, Sendable {
        package var login: String
        package var picture: URL?

        package init(login: String, picture: URL?) {
            self.login = login
            self.picture = picture
        }
    }

    package struct StackPlace: Codable, Hashable, Sendable {
        package var number: Int
        package var position: Int  // 1 is closest to the base branch

        package init(number: Int, position: Int) {
            self.number = number
            self.position = position
        }
    }

    package var id: String
    package var number: Int
    package var title: String
    package var url: URL
    package var repository: String
    package var baseBranch: String
    package var headBranch: String
    package var author: Author
    package var createdAt: Date
    package var updatedAt: Date
    package var isDraft: Bool
    package var isInMergeQueue: Bool
    package var decision: Verdict?  // nil when the repository requires no review or none is in yet
    package var reviews: [Review]  // each reviewer's latest review that approves or asks for changes
    package var checks: Checks
    package var stack: StackPlace?

    package init(
        id: String,
        number: Int,
        title: String,
        url: URL,
        repository: String,
        baseBranch: String,
        headBranch: String,
        author: Author,
        createdAt: Date,
        updatedAt: Date,
        isDraft: Bool,
        isInMergeQueue: Bool,
        decision: Verdict?,
        reviews: [Review],
        checks: Checks,
        stack: StackPlace?
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.url = url
        self.repository = repository
        self.baseBranch = baseBranch
        self.headBranch = headBranch
        self.author = author
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDraft = isDraft
        self.isInMergeQueue = isInMergeQueue
        self.decision = decision
        self.reviews = reviews
        self.checks = checks
        self.stack = stack
    }

    package var verdict: Verdict? {
        if let decision { return decision }
        if reviews.contains(where: { $0.verdict == .changesRequested }) { return .changesRequested }
        return reviews.isEmpty ? nil : .approved
    }

    package var state: State {
        if isInMergeQueue { return .merging }
        if isDraft { return .draft }
        return switch verdict {
        case .changesRequested: .changesRequested
        case .approved: .approved
        case nil: .open
        }
    }

    package var repositoryName: String {
        repository.split(separator: "/").last.map(String.init) ?? repository
    }
}
