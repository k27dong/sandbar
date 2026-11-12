import AppKit
import SandbarCore
import SandbarTestSupport
import SandbarUI
import SwiftUI
import Testing

@Suite(.serialized) struct SetupPictures {
    private static let firstRow: CGFloat = 6 + 49
    private static let rowHeight: CGFloat = 46
    private static let doneMiddle: CGFloat = firstRow + 3 * rowHeight + 4 + 11
    private static let buttonsEnd: CGFloat = 440 - 6 - 10

    private func pictures(_ name: String, of model: AppModel) throws -> [NSBitmapImageRep] {
        try [false, true].map { dark in
            let file = try Pictures.draw(PanelView().environment(model), named: "setup-\(name)", dark: dark)
            let picture = try #require(NSBitmapImageRep(data: try Data(contentsOf: file)))
            #expect(picture.pixelsWide == 880, "\(name)")
            return picture
        }
    }

    private func ink(_ picture: NSBitmapImageRep, x: CGFloat, y: CGFloat) throws -> NSColor {
        try #require(picture.colorAt(x: Int(x * 2), y: Int(y * 2)))
    }

    private func background(_ picture: NSBitmapImageRep) throws -> NSColor {
        try ink(picture, x: 3, y: 3)
    }

    private func rowMiddle(_ row: Int) -> CGFloat {
        Self.firstRow + Self.rowHeight * (CGFloat(row) + 0.5)
    }

    private func buttonInk(
        _ picture: NSBitmapImageRep, middle: CGFloat, fromItsEnd inset: CGFloat = 5
    ) throws -> NSColor {
        try ink(picture, x: Self.buttonsEnd - inset, y: middle - 8)  // above the words, so that no letter is hit
    }

    private func isBlue(_ color: NSColor) -> Bool {
        color.blueComponent - color.redComponent > 0.3
    }

    private func isGray(_ button: NSColor, in picture: NSBitmapImageRep) throws -> Bool {
        button != (try background(picture)) && !isBlue(button)
    }

    private func isConnected(_ picture: NSBitmapImageRep, row: Int) throws -> Bool {
        let mark = try ink(picture, x: Self.buttonsEnd - 7, y: rowMiddle(row) - 3.5)
        return mark.greenComponent - max(mark.redComponent, mark.blueComponent) > 0.2
    }

    private func hasWarningText(_ picture: NSBitmapImageRep, rowTop: CGFloat) -> Bool {
        let secondLine = Int((rowTop + 24) * 2)
        return (secondLine..<secondLine + 30).contains { y in
            (80..<600).contains { x in
                guard let color = picture.colorAt(x: x, y: y) else { return false }
                return color.redComponent - color.blueComponent > 0.3 && color.redComponent > color.greenComponent
            }
        }
    }

    private func blueSpan(_ picture: NSBitmapImageRep, from top: CGFloat, to bottom: CGFloat) -> ClosedRange<Int>? {
        let blue = (0..<picture.pixelsWide).filter { x in
            (Int(top * 2)..<Int(bottom * 2)).contains { y in picture.colorAt(x: x, y: y).map(isBlue) ?? false }
        }
        guard let first = blue.first, let last = blue.last else { return nil }
        return first / 2...last / 2
    }

    private func withGitHubConnectedBeforeSetupEnds(_ body: @MainActor (Home) async throws -> Void) async throws {
        try await withHome { home in
            Preferences(defaults: home.defaults).isSetUp = false
            try await body(home)
        }
    }

    @Test func firstLaunchOffersGitHubFirstAndAToolsButtonOnceItIsKnown() async throws {
        try await withHome(fresh: true) { home in
            let model = home.model()
            for picture in try pictures("first", of: model) {
                #expect(picture.pixelsHigh == 237 * 2)
                #expect(isBlue(try buttonInk(picture, middle: rowMiddle(0))))
                #expect(try buttonInk(picture, middle: rowMiddle(0), fromItsEnd: 90) == background(picture), "Connect")
                #expect(try buttonInk(picture, middle: rowMiddle(1)) == background(picture))
                #expect(try buttonInk(picture, middle: rowMiddle(2)) == background(picture))
                #expect(!hasWarningText(picture, rowTop: Self.firstRow))
            }

            model.panelOpened()
            try await eventually("the lookup ends") { !model.existingSignIns.isEmpty }
            for picture in try pictures("first-not-signed-in", of: model) {
                #expect(picture.pixelsHigh == 237 * 2)
                #expect(isBlue(try buttonInk(picture, middle: rowMiddle(0))))
                #expect(try isGray(try buttonInk(picture, middle: rowMiddle(1)), in: picture))
                #expect(try isGray(try buttonInk(picture, middle: rowMiddle(2)), in: picture))
            }
        }
    }

    @Test func theCodeTakesThePanelAndBackMovesToTheEndWhileWaiting() async throws {
        try await withHome(fresh: true) { home in
            let github = GitHubStub()
            let model = home.model(send: github.send, sleep: { _ in try await Task.sleep(for: .seconds(30)) })
            Task { await model.connectGitHub() }
            try await eventually("the code shows") { model.gitHub != .none }
            for picture in try pictures("code", of: model) {
                #expect(picture.pixelsHigh == 223 * 2)
                let button = try #require(blueSpan(picture, from: 147, to: 157))
                #expect(button.lowerBound > 100 && button.upperBound < 340, "\(button)")
                #expect(abs(button.lowerBound + button.upperBound - 440) <= 2, "in the middle: \(button)")
                let back = try #require(blueSpan(picture, from: 190, to: 212))
                #expect(back.upperBound < 60, "\(back)")
            }

            model.openGitHubForCode()
            for picture in try pictures("code-waiting", of: model) {
                #expect(picture.pixelsHigh == 223 * 2)
                let back = try #require(blueSpan(picture, from: 190, to: 212))
                #expect(back.lowerBound > 380, "\(back)")
            }
            model.cancelGitHubSignIn()
            try await eventually("the sign-in ends") { !model.isSigningIn }
        }
    }

    @Test func aCodeThatExpiredIsSaidInTheRow() async throws {
        try await withHome(fresh: true) { home in
            let github = GitHubStub()
            await github.answerTheCodeWith(#"{"error": "expired_token"}"#)
            let model = home.model(send: github.send)
            try await ends("the code sign-in ends") { await model.connectGitHub() }
            for picture in try pictures("code-expired", of: model) {
                #expect(picture.pixelsHigh == 237 * 2)
                #expect(hasWarningText(picture, rowTop: Self.firstRow))
                #expect(isBlue(try buttonInk(picture, middle: rowMiddle(0))))
            }
        }
    }

    @Test func ghsSignInIsOfferedInPlaceOfConnect() async throws {
        try await withHome(fresh: true) { home in
            let model = home.model(findTool: Fake.found(["gh": try Fake.gh()]))
            model.panelOpened()
            try await eventually("gh is found signed in") { model.canUseGh }
            for picture in try pictures("gh", of: model) {
                #expect(picture.pixelsHigh == 237 * 2)
                #expect(isBlue(try buttonInk(picture, middle: rowMiddle(0))))
                #expect(isBlue(try buttonInk(picture, middle: rowMiddle(0), fromItsEnd: 90)), "the longer words")
            }
        }
    }

    @Test func withGitHubConnectedTheNextToolIsBlueAndDoneAppears() async throws {
        try await withGitHubConnectedBeforeSetupEnds { home in
            let model = home.model(findTool: Fake.found(["claude": try Fake.claude(ownSignIn: true)]))
            model.panelOpened()
            try await eventually("the lookup ends") { !model.existingSignIns.isEmpty }
            for picture in try pictures("connected", of: model) {
                #expect(picture.pixelsHigh == 269 * 2)
                #expect(try isConnected(picture, row: 0))
                #expect(isBlue(try buttonInk(picture, middle: rowMiddle(1))), "Use it")
                let signIn = try buttonInk(picture, middle: rowMiddle(2))
                #expect(try isGray(signIn, in: picture), "Sign in")
                #expect(try buttonInk(picture, middle: Self.doneMiddle) == signIn, "Done")
            }
        }
    }

    @Test func claudeWaitingForTheBrowserHasItsCodeFieldAndDimsTheOtherRows() async throws {
        try await withGitHubConnectedBeforeSetupEnds { home in
            let model = home.model(findTool: Fake.found(["claude": try Fake.claude()]))
            model.panelOpened()
            try await eventually("the lookup ends") { !model.existingSignIns.isEmpty }
            let before = try pictures("claude-to-sign-in", of: model)

            Task { await model.addAccount(.claude) }
            try await eventually("the browser is waited for") { model.signInStep[.claude] == .waitingForBrowser }
            for (picture, before) in zip(try pictures("claude-waiting", of: model), before) {
                #expect(picture.pixelsHigh == before.pixelsHigh + 32 * 2)
                #expect(try isGray(try buttonInk(picture, middle: rowMiddle(1)), in: picture), "Cancel")
                let field = try ink(picture, x: 200, y: Self.firstRow + 2 * Self.rowHeight + 2 + 4)
                #expect(field != (try background(picture)), "the code field")
                let dimmed = try buttonInk(picture, middle: rowMiddle(2) + 32)
                #expect(dimmed != (try background(picture)), "Sign in is still there")
                #expect(dimmed != (try buttonInk(before, middle: rowMiddle(2))), "and dimmed")
            }

            model.pasteCode("another-code")
            try await eventually("the sign-in ends") { !model.isSigningIn }
            for picture in try pictures("claude-failed", of: model) {
                #expect(hasWarningText(picture, rowTop: Self.firstRow + Self.rowHeight))
                #expect(isBlue(try buttonInk(picture, middle: rowMiddle(1))), "Sign in, to try again")
            }
        }
    }

    @Test func aToolBeingFetchedHasCancelAndNoField() async throws {
        try await withGitHubConnectedBeforeSetupEnds { home in
            let model = home.model(toolDownload: Maker(stalls: true).download)
            model.panelOpened()
            try await eventually("the lookup ends") { !model.existingSignIns.isEmpty }
            Task { await model.addAccount(.codex) }
            try await eventually("the copy is being fetched") { model.signInStep[.codex] == .fetching }
            for picture in try pictures("fetching", of: model) {
                #expect(picture.pixelsHigh == 269 * 2)
                #expect(try isGray(try buttonInk(picture, middle: rowMiddle(2)), in: picture), "Cancel")
            }
            model.cancelSignIn(.codex)
            try await eventually("the sign-in ends") { !model.isSigningIn }
        }
    }

    @Test func doneIsBlueOnceAllThreeAreConnected() async throws {
        try await withGitHubConnectedBeforeSetupEnds { home in
            var snapshot = Snapshot.empty
            snapshot.accounts = [
                Snapshot.AccountLimits(
                    account: Account(tool: .claude, name: "Acme Robotics", plan: "Enterprise", profile: nil),
                    limits: Snapshot.Reading(value: [])),
                Snapshot.AccountLimits(
                    account: Account(tool: .codex, name: "Codex", plan: "", profile: nil),
                    limits: Snapshot.Reading(value: [])),
            ]
            for picture in try pictures("done", of: home.model(snapshot: snapshot)) {
                #expect(picture.pixelsHigh == 269 * 2)
                for row in 0...2 { #expect(try isConnected(picture, row: row), "row \(row)") }
                #expect(isBlue(try buttonInk(picture, middle: Self.doneMiddle)))
            }
        }
    }

    @Test func aHiddenOrganizationIsNamedAndGhOfferedWhenItIsThere() async throws {
        try await withGitHubConnectedBeforeSetupEnds { home in
            var snapshot = Snapshot.empty
            snapshot.pullRequests.value.hiddenOrganizations = ["acme", "globex"]
            for picture in try pictures("hidden", of: home.model(snapshot: snapshot)) {
                #expect(try isConnected(picture, row: 0))
                #expect(!hasWarningText(picture, rowTop: Self.firstRow))
            }

            let model = home.model(snapshot: snapshot, findTool: Fake.found(["gh": try Fake.gh()]))
            model.panelOpened()
            try await eventually("gh is found signed in") { model.canUseGh }
            try await home.settled()
            for picture in try pictures("hidden-gh", of: model) {
                #expect(picture.pixelsHigh == 269 * 2)
                #expect(
                    try isGray(try buttonInk(picture, middle: rowMiddle(0), fromItsEnd: 90), in: picture),
                    "Use gh's sign-in, in gray")
            }
        }
    }

    @Test func afterSetupASignInThatStoppedWorkingPutsTheGitHubRowAboveTheList() async throws {
        try await withHome { home in
            let day = try #require(try pictures("day", of: home.model(snapshot: stage("day"))).first)
            let rowTop: CGFloat = 6 + 100 + 9
            var snapshot = stage("day")
            snapshot.pullRequests.trouble = .signedOut
            snapshot.pullRequests.detail = "GitHub sign-in is missing or no longer valid."
            for picture in try pictures("signed-out", of: home.model(snapshot: snapshot)) {
                #expect(picture.pixelsHigh == day.pixelsHigh + (46 + 9) * 2)
                #expect(isBlue(try buttonInk(picture, middle: rowTop + 23)), "Connect")
                #expect(hasWarningText(picture, rowTop: rowTop), "and why")
            }

            let model = home.model(snapshot: stage("day"))
            model.signOutOfGitHub()
            for picture in try pictures("signed-out-by-him", of: model) {
                #expect(picture.pixelsHigh == (6 + 100 + 9 + 46 + 9 + 26 + 9 + 29 + 6) * 2)
                #expect(isBlue(try buttonInk(picture, middle: rowTop + 23)), "Connect")
                #expect(!hasWarningText(picture, rowTop: rowTop))
            }
        }
    }

    @Test func aShownSnapshotHasNoGitHubRow() throws {
        let shown = try #require(try pictures("shown", of: AppModel(showing: stageFile("day"))).first)
        #expect(shown.pixelsHigh == 408 * 2)
    }
}
