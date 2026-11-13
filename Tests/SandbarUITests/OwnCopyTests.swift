import Foundation
import SandbarCore
import SandbarUI
import Testing

@Suite(.serialized) struct OwnCopyTests {
    @Test func sandbarsOwnCopyIsNoSignInOfTheUsers() async throws {
        try await withHome(fresh: true) { home in
            _ = try Fake.keep(
                try Fake.claude(ownSignIn: true), asSandbarsCopyOf: .claude, version: "2.1.400", in: home.files)
            let model = home.model()
            model.panelOpened()
            try await eventually("the lookup ends") { !model.existingSignIns.isEmpty }
            #expect(model.existingSignIns[.claude] == .absent)

            try await ends("the sign-in on this Mac is taken or refused") { await model.useExisting(.claude) }
            #expect(model.signInStep[.claude] == .failed("Claude Code was not found."))
            #expect(model.accounts.isEmpty)
        }
    }

    @Test func withNoToolAnywhereSandbarFetchesItsOwnCopyFirst() async throws {
        try await withHome { home in
            let arrives = Gate()
            let maker = Maker(giving: try Fake.claude(), gate: arrives)
            let model = home.model(toolDownload: maker.download)
            model.start()

            Task { await model.addAccount(.claude) }
            try await eventually("the copy is being fetched") { model.signInStep[.claude] == .fetching }
            #expect(try entries(of: home.files.profiles).isEmpty)
            #expect(model.isSigningIn)

            await arrives.open()
            try await eventually("the browser is waited for") { model.signInStep[.claude] == .waitingForBrowser }
            let copy = home.files.tools.appending(path: "claude/2.1.400/claude")
            #expect(FileManager.default.isExecutableFile(atPath: copy.path))

            model.pasteCode("code-123")
            try await eventually("the sign-in ends") { !model.isSigningIn }
            #expect(model.accounts.map(\.title) == ["Acme Robotics (Enterprise)"])
            #expect(model.signInStep[.claude] == .idle)
            try await eventually("the limits are read through the copy") {
                model.snapshot.accounts.first?.limits.value.map(\.label) == ["Week"]
            }
        }
    }

    @Test func cancellingTheFetchLeavesNothing() async throws {
        try await withHome { home in
            let maker = Maker(giving: try Fake.claude(), stalls: true)
            let model = home.model(toolDownload: maker.download)
            model.start()
            Task { await model.addAccount(.claude) }
            try await eventually("the copy is being fetched") { model.signInStep[.claude] == .fetching }

            model.cancelSignIn(.claude)
            try await eventually("the sign-in ends") { !model.isSigningIn }
            #expect(model.signInStep[.claude] == .idle)
            #expect(model.accounts.isEmpty)
            #expect(try entries(of: home.files.profiles).isEmpty)
            #expect(try entries(of: home.files.tools).isEmpty)
        }
    }

    @Test func aFetchThatFailsSaysSo() async throws {
        try await withHome { home in
            let model = home.model()
            model.start()
            try await ends("the sign-in ends") { await model.addAccount(.codex) }
            #expect(model.signInStep[.codex] == .failed("Codex could not be fetched."))
            let profiles = try entries(of: home.files.profiles)
            #expect(profiles.isEmpty)
        }
    }
}
