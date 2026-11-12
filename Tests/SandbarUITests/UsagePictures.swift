import AppKit
import SandbarCore
import SandbarUI
import SwiftUI
import Testing

@Suite(.serialized) struct UsagePictures {
    private func picture(_ name: String, of snapshot: Snapshot, showsPace: Bool = false, dark: Bool = false)
        async throws -> NSBitmapImageRep
    {
        var picture: NSBitmapImageRep?
        try await withDefaults { defaults in
            let model = AppModel(
                snapshot: snapshot, preferences: Preferences(defaults: defaults), now: AppModelTests.now)
            model.preferences.showsPace = showsPace
            let rows = UsageRows().environment(model).font(.system(size: 13)).padding(.horizontal, 6).frame(width: 440)
            let file = try Pictures.draw(rows, named: "usage-\(name)", dark: dark)
            picture = NSBitmapImageRep(data: try Data(contentsOf: file))
        }
        let drawn = try #require(picture)
        #expect(drawn.pixelsWide == 880, "\(name)")
        return drawn
    }

    @Test func everyLimitHasItsRow() async throws {
        for name in ["day", "limit"] {
            for dark in [false, true] {
                #expect(try await picture(name, of: stage(name), dark: dark).pixelsHigh == (3 + 4 * 24 + 1) * 2)
            }
        }
    }

    @Test func thePaceMarkCutsTheBar() async throws {
        let pace = try #require(stage("day").accounts[0].limits.value[0].pace(now: AppModelTests.now))
        let barStart: Double = 6 + 10 + 16 + 8 + 72 + 8 + 36 + 8
        let gap = Int((barStart + 140 * pace) * 2)
        for dark in [false, true] {
            let plain = try await picture("day", of: stage("day"), dark: dark)
            let paced = try await picture("day-pace", of: stage("day"), showsPace: true, dark: dark)
            #expect(paced.pixelsHigh == plain.pixelsHigh)
            #expect(plain.colorAt(x: gap, y: 30) == plain.colorAt(x: gap - 8, y: 30))
            #expect(paced.colorAt(x: gap, y: 30) == paced.colorAt(x: 4, y: 30), "the background shows through")
        }
    }

    @Test func anAccountInTroubleKeepsItsRowsDimmed() async throws {
        var snapshot = stage("day")
        snapshot.accounts[1].limits.trouble = .signedOut
        snapshot.accounts[1].limits.detail = "Signed out."
        let personal = (3 + 24) * 2
        let nameColumn = { (picture: NSBitmapImageRep) in
            (40 * 2..<112 * 2).flatMap { x in (personal..<personal + 48).map { picture.colorAt(x: x, y: $0) } }
        }
        for dark in [false, true] {
            let plain = try await picture("day", of: stage("day"), dark: dark)
            let dimmed = try await picture("day-trouble", of: snapshot, dark: dark)
            #expect(dimmed.pixelsHigh == plain.pixelsHigh)
            #expect(nameColumn(dimmed) == nameColumn(plain), "the name keeps its ink")
            #expect(dimmed.colorAt(x: 170 * 2, y: personal + 24) != plain.colorAt(x: 170 * 2, y: personal + 24))
        }
    }

    @Test func anAccountWithNoLimitsHasOneRow() async throws {
        var snapshot = Snapshot.empty
        snapshot.accounts = [
            Snapshot.AccountLimits(
                account: Account(tool: .codex, name: "Personal", plan: "Plus", profile: nil),
                limits: Snapshot.Reading(value: [], readAt: AppModelTests.now))
        ]
        for dark in [false, true] {
            let drawn = try await picture("no-limits", of: snapshot, dark: dark)
            #expect(drawn.pixelsHigh == (3 + 24 + 1) * 2)
            #expect(drawn.colorAt(x: 165 * 2, y: 30) == drawn.colorAt(x: 300 * 2, y: 30), "the bar has no fill")
        }
    }
}
