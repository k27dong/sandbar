import AppKit
import Carbon.HIToolbox
import SandbarCore
import SandbarUI
import Testing

@Suite(.serialized) struct KeyboardTests {
    private static let surveyStack = "acme/storefront#14"

    private func row(_ number: Int, in repository: String = "acme/storefront") -> AppModel.Selection {
        .pullRequest("PR_\(repository)#\(number)")
    }

    private func walkedDown(_ model: AppModel, rows: Int) -> [AppModel.Selection?] {
        (0..<rows).map { _ in
            model.moveSelection(by: 1)
            return model.selection
        }
    }

    @Test func nothingIsSelectedAtFirstAndDownWalksTheReviewRequestsThenHisRows() async throws {
        try await withHome { home in
            let model = home.model(snapshot: stage("day"))
            #expect(model.selection == nil)
            #expect(
                walkedDown(model, rows: 6) == [
                    row(6821, in: "acme/api"), row(6816, in: "acme/api"), row(40790), row(41252), row(41251),
                    row(41250),
                ])
        }
    }

    @Test func upAtTheTopAndDownAtTheBottomStay() async throws {
        try await withHome { home in
            let model = home.model(snapshot: stage("day"))
            model.moveSelection(by: 1)
            model.moveSelection(by: -1)
            #expect(model.selection == row(6821, in: "acme/api"))

            let last = row(104, in: "acme/tools")
            #expect(Array(walkedDown(model, rows: 9).suffix(2)) == [last, last])
        }
    }

    @Test func theFirstUpSelectsTheLastRowShown() async throws {
        try await withHome { home in
            let model = home.model(snapshot: stage("day"))
            model.moveSelection(by: -1)
            #expect(model.selection == row(104, in: "acme/tools"))
        }
    }

    @Test func returnOnAFoldRowOpensTheStackAndTheNextDownSelectsTheRowThatAppeared() async throws {
        try await withHome { home in
            let model = home.model(snapshot: stage("many"))
            #expect(Array(walkedDown(model, rows: 6).suffix(2)) == [row(40790), .fold(Self.surveyStack)])

            model.openSelection()
            #expect(model.openStacks == [Self.surveyStack])
            #expect(model.selection == .fold(Self.surveyStack))
            model.moveSelection(by: 1)
            #expect(model.selection == row(41309))

            model.moveSelection(by: -1)
            model.openSelection()
            #expect(model.openStacks.isEmpty, "Return on the fold row of an open stack folds it")
            model.moveSelection(by: 1)
            #expect(model.selection == row(41302))
        }
    }

    @Test func aStackSetToBottomFirstIsWalkedFromItsBottomToItsFoldRow() async throws {
        try await withHome { home in
            let model = home.model(snapshot: stage("many"))
            model.preferences.stackOrder = .bottomFirst
            #expect(
                Array(walkedDown(model, rows: 8).suffix(3)) == [row(41301), row(41302), .fold(Self.surveyStack)])
        }
    }

    @Test func returnOnAPullRequestOpensItAndClosesThePanel() async throws {
        try await withHome { home in
            let opened = Opened()
            var closes = 0
            let model = home.model(snapshot: stage("day"), openAddress: { opened.addresses.append($0) })
            model.closePanel = { closes += 1 }

            model.openSelection()
            #expect(opened.addresses.isEmpty, "nothing is selected")

            model.moveSelection(by: 1)
            model.openSelection()
            #expect(opened.addresses.map(\.absoluteString) == ["https://github.com/acme/api/pull/6821"])
            #expect(closes == 1)
        }
    }

    @Test func aKeyPressIsThePanelsOnlyInThePanelsOwnWindow() async throws {
        try await withHome { home in
            let model = home.model(snapshot: stage("day"))
            let panel = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            let settings = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            try #require(panel.windowNumber != settings.windowNumber)
            var closes = 0
            let passedOn = { (key: Int, window: NSWindow, modifiers: NSEvent.ModifierFlags) in
                let press = try #require(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: "",
                        charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(key)))
                return PanelWindow.keyDown(press, in: panel, showing: model) { closes += 1 } === press
            }

            for key in [kVK_DownArrow, kVK_UpArrow, kVK_Return, kVK_Escape] {
                let typedIntoSettings = try passedOn(key, settings, [])
                #expect(typedIntoSettings, "key \(key)")
            }
            #expect(model.selection == nil)
            #expect(closes == 0)

            let down = try passedOn(kVK_DownArrow, panel, [])
            #expect(!down)
            #expect(model.selection == row(6821, in: "acme/api"))
            let commandDown = try passedOn(kVK_DownArrow, panel, .command)
            let letter = try passedOn(kVK_ANSI_A, panel, [])
            #expect(commandDown && letter)
            #expect(model.selection == row(6821, in: "acme/api"))
            let escape = try passedOn(kVK_Escape, panel, [])
            #expect(!escape)
            #expect(closes == 1)
        }
    }

    @Test func nothingIsSelectedEachTimeThePanelOpens() async throws {
        try await withHome { home in
            let model = home.model(snapshot: stage("day"))
            model.moveSelection(by: 1)
            model.panelOpened()
            #expect(model.selection == nil)
        }
    }

    @Test func aSelectedRowThatIsNoLongerShownCountsAsNone() async throws {
        try await withHome { home in
            let opened = Opened()
            let model = home.model(snapshot: stage("day"), openAddress: { opened.addresses.append($0) })
            model.moveSelection(by: 1)
            model.preferences.chosenRepositories = ["acme/storefront"]

            model.openSelection()
            #expect(opened.addresses.isEmpty)
            model.moveSelection(by: 1)
            #expect(model.selection == row(40790))
        }
    }

    @Test func beforeSetupIsFinishedTheArrowKeysSelectNothing() async throws {
        try await withHome(fresh: true) { home in
            let model = home.model(snapshot: stage("day"))
            model.moveSelection(by: 1)
            #expect(model.selection == nil)
        }
    }

    @Test func whileTheGitHubCodeShowsTheArrowKeysAndReturnDoNothing() async throws {
        try await withHome { home in
            let github = GitHubStub()
            let opened = Opened()
            let model = home.model(
                snapshot: stage("day"), send: github.send, sleep: { _ in try await Task.sleep(for: .seconds(30)) },
                openAddress: { opened.addresses.append($0) })
            model.moveSelection(by: 1)
            Task { await model.connectGitHub() }
            try await eventually("the code shows") { model.gitHub != .connected(login: "kd", throughGh: false) }

            model.openSelection()
            #expect(opened.addresses.isEmpty, "the selected row is not on screen")
            model.moveSelection(by: 1)
            #expect(model.selection == nil)

            model.cancelGitHubSignIn()
            try await eventually("the sign-in ends") { !model.isSigningIn }
        }
    }
}
