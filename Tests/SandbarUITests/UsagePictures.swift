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

    private func pixels(_ picture: NSBitmapImageRep) throws -> Data {
        Data(bytes: try #require(picture.bitmapData), count: picture.bytesPerRow * picture.pixelsHigh)
    }

    @Test func everyLimitHasItsRow() async throws {
        for name in ["day", "limit"] {
            for dark in [false, true] {
                #expect(try await picture(name, of: stage(name), dark: dark).pixelsHigh == (3 + 4 * 24 + 1) * 2)
            }
        }
    }

    @Test func thePaceMarkCutsTheBar() async throws {
        for dark in [false, true] {
            let plain = try await picture("day", of: stage("day"), dark: dark)
            let paced = try await picture("day-pace", of: stage("day"), showsPace: true, dark: dark)
            #expect(paced.pixelsHigh == plain.pixelsHigh)
            #expect(try pixels(paced) != pixels(plain))
        }
    }

    @Test func anAccountInTroubleKeepsItsRowsDimmed() async throws {
        var snapshot = stage("day")
        snapshot.accounts[1].limits.trouble = .signedOut
        snapshot.accounts[1].limits.detail = "Signed out."
        for dark in [false, true] {
            let plain = try await picture("day", of: stage("day"), dark: dark)
            let dimmed = try await picture("day-trouble", of: snapshot, dark: dark)
            #expect(dimmed.pixelsHigh == plain.pixelsHigh)
            #expect(try pixels(dimmed) != pixels(plain))
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
            #expect(try await picture("no-limits", of: snapshot, dark: dark).pixelsHigh == (3 + 24 + 1) * 2)
        }
    }
}
