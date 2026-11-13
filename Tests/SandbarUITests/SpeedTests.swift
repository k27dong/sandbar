import AppKit
import SandbarCore
import SandbarUI
import SwiftUI
import Testing

@Suite(.serialized) struct SpeedTests {
    @Test func aPanelOfSixtyPullRequestsIsHostedLaidOutAndDrawnInUnder200Milliseconds() async throws {
        try await withDefaults { defaults in
            let model = AppModel(snapshot: stage("sixty"), preferences: afterSetup(defaults), now: AppModelTests.now)
            let panel = PanelView().environment(model)
            let tries = try (0..<5).map { _ in
                try ContinuousClock().measure { _ = try Pictures.bitmap(of: panel) }
            }
            let middle = tries.sorted()[2]
            #expect(middle < .milliseconds(200), "\(tries)")

            _ = try Pictures.draw(panel, named: "panel-sixty")
            let milliseconds = tries.map { "\(Int(($0 / .milliseconds(1)).rounded()))" }.joined(separator: ", ")
            try Data("five tries in milliseconds: \(milliseconds)\n".utf8)
                .write(to: Pictures.folder.appendingPathComponent("panel-sixty-speed.txt"))
        }
    }
}
