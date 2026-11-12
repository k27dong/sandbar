import Foundation
import SandbarCore

enum Sample {
    static let now = Date(timeIntervalSince1970: 1_794_506_400)  // 2026-11-12 18:00 UTC
}

extension PullRequest {
    static func sample(
        _ number: Int,
        title: String = "Show the delivery date on the order summary",
        repository: String = "acme/storefront",
        baseBranch: String = "master",
        headBranch: String? = nil,
        author: String = "kd",
        createdAt: Date = Sample.now - 86_400,
        updatedAt: Date = Sample.now - 86_400,
        isDraft: Bool = false,
        isInMergeQueue: Bool = false,
        decision: Verdict? = nil,
        reviews: [Review] = [],
        checks: Checks = Checks(verdict: nil),
        stack: StackPlace? = nil
    ) -> PullRequest {
        PullRequest(
            id: "PR_\(repository)#\(number)",
            number: number,
            title: title,
            url: URL(string: "https://github.com/\(repository)/pull/\(number)")!,
            repository: repository,
            baseBranch: baseBranch,
            headBranch: headBranch ?? "change-\(number)",
            author: Author(login: author, picture: nil),
            createdAt: createdAt,
            updatedAt: updatedAt,
            isDraft: isDraft,
            isInMergeQueue: isInMergeQueue,
            decision: decision,
            reviews: reviews,
            checks: checks,
            stack: stack
        )
    }
}
