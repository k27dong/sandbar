import AppKit
import SandbarCore
import SandbarUI
import SwiftUI
import Testing

@Suite(.serialized) struct SettingsPictures {
    private func pictures(_ name: String, of view: some View) throws -> [NSBitmapImageRep] {
        try [false, true].map { dark in
            let file = try Pictures.draw(view, named: "settings-\(name)", dark: dark)
            let picture = try #require(NSBitmapImageRep(data: try Data(contentsOf: file)))
            return picture
        }
    }

    private func pane(_ pane: SettingsWindow.Pane, of model: AppModel) throws -> [NSBitmapImageRep] {
        let pictures = try pictures(pane.rawValue, of: SettingsView(pane: pane, version: "0.1.0").environment(model))
        for picture in pictures { #expect(picture.pixelsWide == 1000, "\(pane)") }
        return pictures
    }

    private func height(_ pictures: [NSBitmapImageRep]) throws -> Int {
        let light = try #require(pictures.first)
        #expect(pictures.allSatisfy { $0.pixelsHigh == light.pixelsHigh }, "light and dark alike")
        return light.pixelsHigh / 2
    }

    private static let accounts: Snapshot = {
        var snapshot = Snapshot.empty
        snapshot.accounts = [
            Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil),
            Account(tool: .claude, name: "Personal", plan: "Ultra", profile: nil),
            Account(tool: .codex, name: "Work", plan: "Business", profile: nil),
        ].map { Snapshot.AccountLimits(account: $0, limits: Snapshot.Reading(value: [])) }
        return snapshot
    }()

    @Test func everyPaneIsAsTallAsItsRows() async throws {
        try await withHome { home in
            home.launchesAtLogin = true
            let general = try height(try pane(.general, of: home.model()))
            let menuBar = try height(try pane(.menuBar, of: home.model()))
            let accounts = try height(try pane(.accounts, of: home.model(snapshot: Self.accounts)))
            let notifications = try height(try pane(.notifications, of: home.model()))
            #expect(general > 120 && general < menuBar, "three rows in two groups: \(general)")
            #expect(menuBar > 250 && menuBar < notifications, "five rows in two groups: \(menuBar)")
            #expect(notifications < accounts, "six rows and a line: \(notifications), \(accounts)")
            #expect(accounts < 800, "seven rows in three groups: \(accounts)")
        }
    }

    @Test func anAccountThatCannotBeReadSaysWhyUnderItsName() async throws {
        try await withHome { home in
            var troubled = Self.accounts
            troubled.accounts[2].limits = Snapshot.Reading(value: [], trouble: .signedOut, detail: "Signed out.")
            let plain = try height(try pane(.accounts, of: home.model(snapshot: Self.accounts)))
            let withTrouble = try height(
                try pictures(
                    "accounts-trouble",
                    of: SettingsView(pane: .accounts, version: "0.1.0").environment(home.model(snapshot: troubled))))
            #expect(withTrouble > plain + 4, "one more line: \(plain), \(withTrouble)")
        }
    }

    @Test func aRefusedShortcutIsSaidUnderItsRow() async throws {
        try await withHome { home in
            let model = home.model()
            let plain = try height(try pane(.general, of: model))
            model.shortcutIsRefused = true
            let refused = try height(
                try pictures("general-refused", of: SettingsView(pane: .general, version: "0.1.0").environment(model)))
            #expect(refused > plain + 4, "one more line: \(plain), \(refused)")
        }
    }

    @Test func aBundleWithNoVersionHasNoVersionRow() async throws {
        try await withHome { home in
            let model = home.model()
            let withVersion = try height(try pane(.general, of: model))
            let withoutVersion = try height(
                try pictures("general-no-version", of: SettingsView(pane: .general, version: nil).environment(model)))
            #expect(withoutVersion < withVersion - 20, "one group fewer: \(withVersion), \(withoutVersion)")
        }
    }

    @Test func theRepositorySheetListsTheChosenOnesTooWithNoPullRequestNow() async throws {
        try await withHome { home in
            let model = home.model(snapshot: stage("day"))
            model.choosesRepositories = true
            let listed = try height(try pictures("repositories", of: RepositoryChoice().environment(model)))
            model.choose("acme/web", true)
            let withAnother = try height(try pictures("repositories-more", of: RepositoryChoice().environment(model)))
            #expect(withAnother > listed + 10, "one more row: \(listed), \(withAnother)")
        }
    }
}
