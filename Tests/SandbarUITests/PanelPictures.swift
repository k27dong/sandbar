import AppKit
import SandbarCore
import SandbarUI
import SwiftUI
import Testing

func stageFile(_ name: String) -> URL {
    URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Stages/\(name).json")
}

func stage(_ name: String) -> Snapshot {
    SavedSnapshot.read(from: stageFile(name))
}

@Suite(.serialized) struct PanelPictures {
    nonisolated static let stages: [(name: String, points: Int)] = [
        ("day", 408), ("limit", 408), ("states", 486), ("many", 765), ("offline", 408), ("awkward", 272),
    ]

    private func model(_ snapshot: Snapshot, _ defaults: UserDefaults) -> AppModel {
        AppModel(snapshot: snapshot, preferences: Preferences(defaults: defaults), now: AppModelTests.now)
    }

    private func picture(
        _ name: String, of model: AppModel, maxHeight: CGFloat = .infinity, dark: Bool = false
    ) throws -> NSBitmapImageRep {
        let file = try Pictures.draw(
            PanelView(maxHeight: maxHeight).environment(model), named: "panel-\(name)", dark: dark)
        let picture = try #require(NSBitmapImageRep(data: try Data(contentsOf: file)))
        #expect(picture.pixelsWide == 880, "\(name)")
        return picture
    }

    private func withTheFirstStackOpen(_ model: AppModel) throws -> AppModel {
        let stacks = model.list.mine.compactMap { if case .stack(let stack) = $0 { stack } else { nil } }
        model.openStacks = [try #require(stacks.first).id]
        return model
    }

    @Test(arguments: stages) func everyStageIsAsTallAsInTheDesign(design: (name: String, points: Int)) async throws {
        try await withDefaults { defaults in
            for dark in [false, true] {
                let picture = try picture(design.name, of: model(stage(design.name), defaults), dark: dark)
                #expect(picture.pixelsHigh == design.points * 2)
            }
        }
    }

    @Test func anEmptyListDraws() async throws {
        try await withDefaults { defaults in
            var snapshot = Snapshot.empty
            snapshot.pullRequests.readAt = AppModelTests.now
            for dark in [false, true] {
                _ = try picture("empty", of: model(snapshot, defaults), dark: dark)
            }
        }
    }

    @Test func eachSettingChangesTheRows() async throws {
        let settings: [(name: String, change: (Preferences) -> Void)] = [
            ("twoLines", { $0.titles = .twoLines }), ("sinceUpdate", { $0.time = .sinceUpdate }),
            ("noTime", { $0.time = .off }), ("repository", { $0.showsRepository = true }),
            ("bottomFirst", { $0.stackOrder = .bottomFirst }),
        ]
        for setting in settings {
            try await withDefaults { defaults in
                let model = model(stage("day"), defaults)
                setting.change(model.preferences)
                _ = try picture("day-\(setting.name)", of: model)
            }
        }
    }

    @Test func anOpenStackShowsEveryRow() async throws {
        try await withDefaults { defaults in
            let folded = try picture("many", of: model(stage("many"), defaults))
            for dark in [false, true] {
                let open = try picture(
                    "many-open", of: try withTheFirstStackOpen(model(stage("many"), defaults)), dark: dark)
                #expect(open.pixelsHigh == folded.pixelsHigh + 7 * 26 * 2)
            }
        }
    }

    @Test func aListTallerThanTheLimitScrollsAtItsFullWidthAboveTheFooter() async throws {
        let scrollBars = NSScroller.preferredScrollerStyle == .legacy ? "always" : "when-scrolling"
        try await withDefaults { defaults in
            let model = try withTheFirstStackOpen(model(stage("many"), defaults))
            let whole = try picture("many-open", of: model)
            let limited = try picture("many-limit-scroll-bars-\(scrollBars)", of: model, maxHeight: 700)
            #expect(whole.pixelsHigh > 1_400)
            #expect(limited.pixelsHigh == 1_400)
            let acrossTheFirstRow = { (picture: NSBitmapImageRep) in
                (0..<848).map { picture.colorAt(x: $0, y: 256) }
            }
            #expect(acrossTheFirstRow(limited) == acrossTheFirstRow(whole))
        }
    }

    @Test func noTitleChangesARowsHeight() async throws {
        try await withDefaults { defaults in
            let awkward = stage("awkward")
            var plain = awkward
            for list in [\PullRequestLists.mine, \.reviewRequests] {
                for index in plain.pullRequests.value[keyPath: list].indices {
                    plain.pullRequests.value[keyPath: list][index].title = "Title"
                }
            }
            let expected = try picture("awkward-plain", of: model(plain, defaults))
            #expect(try picture("awkward", of: model(awkward, defaults)).pixelsHigh == expected.pixelsHigh)
        }
    }
}
