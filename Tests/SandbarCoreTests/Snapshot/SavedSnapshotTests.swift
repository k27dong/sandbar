import Foundation
import SandbarCore
import Testing

struct SavedSnapshotTests {
    static let unreadable: [String?] = [nil, "{", #"{"version": 2, "snapshot": {}}"#]

    static let snapshot: Snapshot = {
        var snapshot = Snapshot.empty
        let review = PullRequest.Review(author: "priya", verdict: .approved, submittedAt: Sample.now - 3_600)
        snapshot.pullRequests = Snapshot.Reading(
            value: PullRequestLists(
                mine: [
                    .sample(
                        41, checks: Checks(verdict: .failed, failed: ["build"]),
                        stack: PullRequest.StackPlace(number: 4, position: 1))
                ],
                reviewRequests: [.sample(7, repository: "acme/api", author: "mchen", reviews: [review])],
                hiddenOrganizations: ["acme-labs"]),
            readAt: Sample.now - 60, askedAt: Sample.now, trouble: .offline, detail: "GitHub could not be reached.")
        snapshot.accounts = [
            Snapshot.AccountLimits(
                account: Account(
                    tool: .claude, name: "Work", plan: "Enterprise", profile: URL(filePath: "/profiles/claude-work")),
                limits: Snapshot.Reading(
                    value: [
                        UsageLimit(window: .month, used: 0.62411, dollars: 3120),
                        UsageLimit(
                            window: .other("weekly_scoped"), model: "Fable", used: 0.12,
                            resetsAt: Sample.now + 86_400),
                    ],
                    readAt: Sample.now, askedAt: Sample.now)),
            Snapshot.AccountLimits(
                account: Account(tool: .codex, name: "Personal", plan: "Plus", profile: nil),
                limits: Snapshot.Reading(value: [], askedAt: Sample.now, trouble: .signedOut, detail: "Signed out.")),
        ]
        return snapshot
    }()

    func file() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "sandbar-\(UUID().uuidString)/snapshot.json")
    }

    @Test func aWrittenSnapshotReadsBackEqual() throws {
        let file = file()
        try SavedSnapshot.write(Self.snapshot, to: file)
        #expect(SavedSnapshot.read(from: file) == Self.snapshot)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix("{\n  \"snapshot\" : {"))
        #expect(text.hasSuffix("\"version\" : 1\n}"))
        #expect(text.contains(#""askedAt" : "2026-11-12T18:00:00Z""#))
        #expect(text.contains(#""detail" : "GitHub could not be reached.""#))
    }

    @Test(arguments: unreadable) func whatCannotBeReadIsEmpty(contents: String?) throws {
        let file = file()
        if let contents {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }
        #expect(SavedSnapshot.read(from: file) == .empty)
    }

    @Test func aCopySavedBeforeDetailsReadsWithNone() throws {
        let file = file()
        try SavedSnapshot.write(Self.snapshot, to: file)
        let text = try String(contentsOf: file, encoding: .utf8)
        let withoutDetails = text.replacing(#/\n *"detail" : "[^"]*",/#, with: "")
        #expect(withoutDetails != text)
        #expect(!withoutDetails.contains(#""detail""#))
        try Data(withoutDetails.utf8).write(to: file)
        var expected = Self.snapshot
        expected.pullRequests.detail = nil
        for index in expected.accounts.indices { expected.accounts[index].limits.detail = nil }
        #expect(SavedSnapshot.read(from: file) == expected)
    }

    @Test func aWriteOverAnOldCopyLeavesACompleteFile() throws {
        let file = file()
        try SavedSnapshot.write(.empty, to: file)
        try SavedSnapshot.write(Self.snapshot, to: file)
        #expect(SavedSnapshot.read(from: file) == Self.snapshot)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == [
                "snapshot.json"
            ])
    }
}
