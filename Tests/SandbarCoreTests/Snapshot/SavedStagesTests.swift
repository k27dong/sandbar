import Foundation
import SandbarCore
import Testing

struct SavedStagesTests {
    static let stages: [(name: String, open: Int, stacks: Int, reviewRequests: Int)] = [
        ("first", 0, 0, 0), ("day", 7, 1, 2), ("states", 11, 2, 1), ("many", 34, 4, 4), ("limit", 7, 1, 2),
        ("offline", 7, 1, 2), ("awkward", 3, 0, 1),
    ]

    @Test(arguments: stages) func everyStageFileReads(
        stage: (name: String, open: Int, stacks: Int, reviewRequests: Int)
    ) {
        let file = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Stages/\(stage.name).json")
        let snapshot = SavedSnapshot.read(from: file)
        let lists = snapshot.pullRequests.value
        if stage.name == "first" {
            #expect(lists == Snapshot.empty.pullRequests.value)
        } else {
            #expect(snapshot != .empty)
        }

        let list = PullRequestList(mine: lists.mine, reviewRequests: lists.reviewRequests)
        #expect(list.openCount == stage.open)
        #expect(list.reviewRequests.count == stage.reviewRequests)
        let stacks = list.mine.filter {
            if case .stack = $0 { true } else { false }
        }
        #expect(stacks.count == stage.stacks)
    }
}
