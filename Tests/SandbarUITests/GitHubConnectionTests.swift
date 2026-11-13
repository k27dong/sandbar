import Foundation
import SandbarCore
import SandbarUI
import Testing

@Suite(.serialized) struct GitHubConnectionTests {
    nonisolated static let endings: [(answer: String, note: String)] = [
        (#"{"error": "expired_token"}"#, "The code expired."),
        (#"{"error": "access_denied"}"#, "The sign-in was cancelled on GitHub."),
    ]

    nonisolated static let hidden: [(names: [String], note: String?)] = [
        ([], nil), (["acme"], "Sandbar cannot see acme."), (["acme", "globex"], "Sandbar cannot see acme and globex."),
    ]

    @Test func theKeychainKeepsAValueUntilItIsDeleted() throws {
        let name = "test-\(UUID().uuidString)"
        defer { #expect(throws: Never.self) { try Keychain.delete(name) } }
        #expect(try Keychain.read(name) == nil)

        try Keychain.write("first-made-up-value", as: name)
        #expect(try Keychain.read(name) == "first-made-up-value")

        try Keychain.write("second-made-up-value", as: name)
        #expect(try Keychain.read(name) == "second-made-up-value")

        try Keychain.delete(name)
        #expect(try Keychain.read(name) == nil)
    }

    @Test func connectingShowsTheCodeThenKeepsTheSignIn() async throws {
        try await withHome(fresh: true) { home in
            let github = GitHubStub()
            await github.answerTheCodeWith(#"{"error": "authorization_pending"}"#, GitHubStub.token)
            let approved = Gate()
            let opened = Opened()
            let model = home.model(
                send: github.send, sleep: { _ in await approved.wait() }, openAddress: { opened.addresses.append($0) })
            #expect(model.gitHub == .none)
            #expect(model.needsGitHubSignIn)

            Task { await model.connectGitHub() }
            try await eventually("the code shows") { model.gitHub != .none }
            guard case .code(let code) = model.gitHub else {
                Issue.record("expected the code, got \(model.gitHub)")
                return
            }
            #expect(code.userCode == "WDJB-MJHT")
            #expect(model.isSigningIn)
            #expect(!model.isWaitingForGitHub)
            #expect(opened.addresses.isEmpty)

            model.openGitHubForCode()
            #expect(model.isWaitingForGitHub)
            #expect(opened.addresses == [URL(string: "https://github.com/login/device")!])

            await approved.open()
            try await eventually("the sign-in ends") { !model.isSigningIn }
            #expect(model.gitHub == .connected(login: "kd", throughGh: false))
            #expect(!model.needsGitHubSignIn)
            #expect(!model.isSigningIn)
            #expect(model.gitHubNote == nil)
            #expect(try Keychain.read(home.keychainItem) == "gho_madeup")
            #expect(Preferences(defaults: home.defaults).gitHubLogin == "kd")
            #expect(!Preferences(defaults: home.defaults).usesGhSignIn)

            try await eventually("the pull requests are read") { model.list.openCount == 1 }
            #expect(await github.tokens == ["bearer gho_madeup", "bearer gho_madeup"])
        }
    }

    @Test(arguments: endings) func aCodeSignInThatEndsReturnsToConnectAndSaysWhy(answer: String, note: String)
        async throws
    {
        try await withHome(fresh: true) { home in
            let github = GitHubStub()
            await github.answerTheCodeWith(answer)
            let model = home.model(send: github.send)
            try await ends("the code sign-in ends") { await model.connectGitHub() }
            #expect(model.gitHub == .none)
            #expect(model.gitHubNote == note)
            #expect(!model.isSigningIn)
            let kept = try Keychain.read(home.keychainItem)
            #expect(kept == nil)
            #expect(Preferences(defaults: home.defaults).gitHubLogin == nil)
        }
    }

    @Test func aKeychainThatWillNotKeepTheSignInIsSaid() async throws {
        try await withHome(fresh: true) { home in
            let github = GitHubStub()
            await github.answerTheCodeWith(GitHubStub.token)
            var refusing = Keychain.Item(named: home.keychainItem)
            refusing.write = { _ in throw Keychain.Failure.status(-25308) }
            let model = home.model(send: github.send, keychain: refusing)
            try await ends("the code sign-in ends") { await model.connectGitHub() }
            #expect(model.gitHub == .none)
            #expect(model.gitHubNote == "The sign-in could not be kept in the Keychain.")
            #expect(Preferences(defaults: home.defaults).gitHubLogin == nil)
        }
    }

    @Test func aSignInTheKeychainWillNotLetGoIsSaidAndTheSignOutStillFinishes() async throws {
        try await withHome { home in
            var refusing = Keychain.Item(named: home.keychainItem)
            refusing.delete = { throw Keychain.Failure.status(-25308) }
            let model = home.model(snapshot: stage("day"), keychain: refusing)
            model.signOutOfGitHub()
            #expect(model.gitHubNote == "The sign-in could not be removed from the Keychain.")
            #expect(model.gitHub == .none)
            #expect(Preferences(defaults: home.defaults).gitHubLogin == nil)
            #expect(model.list.openCount == 0)
            #expect(SavedSnapshot.read(from: home.files.snapshot) == model.snapshot)
        }
    }

    @Test func aSwitchToGhStillHappensWhenTheKeychainWillNotLetGoAndSaysSo() async throws {
        try await withHome { home in
            let github = GitHubStub()
            var refusing = Keychain.Item(named: home.keychainItem)
            refusing.delete = { throw Keychain.Failure.status(-25308) }
            let model = home.model(findTool: Fake.found(["gh": try Fake.gh()]), send: github.send, keychain: refusing)
            model.start()
            try await ends("gh's sign-in ends") { await model.useGhSignIn() }
            #expect(model.gitHub == .connected(login: "kd", throughGh: true))
            #expect(model.gitHubNote == "The sign-in could not be removed from the Keychain.")
            #expect(Preferences(defaults: home.defaults).usesGhSignIn)
        }
    }

    @Test func aCodeSignInThatCannotReachGitHubSaysSo() async throws {
        try await withHome(fresh: true) { home in
            let model = home.model()
            try await ends("the code sign-in ends") { await model.connectGitHub() }
            #expect(model.gitHub == .none)
            #expect(model.gitHubNote == "GitHub could not be reached.")
        }
    }

    @Test func theNextAttemptClearsTheNote() async throws {
        try await withHome(fresh: true) { home in
            let github = GitHubStub()
            await github.answerTheCodeWith(#"{"error": "expired_token"}"#)
            let model = home.model(send: github.send, sleep: { _ in try await Task.sleep(for: .seconds(30)) })
            try await ends("the code sign-in ends") { await model.connectGitHub() }
            try #require(model.gitHubNote == "The code expired.")

            Task { await model.connectGitHub() }
            try await eventually("the code shows") { model.gitHub != .none }
            #expect(model.gitHubNote == nil)
            model.cancelGitHubSignIn()
            try await eventually("the sign-in ends") { !model.isSigningIn }
        }
    }

    @Test func backEndsTheCodeSignIn() async throws {
        try await withHome(fresh: true) { home in
            let github = GitHubStub()
            let model = home.model(send: github.send, sleep: { _ in try await Task.sleep(for: .seconds(30)) })
            Task { await model.connectGitHub() }
            try await eventually("the code shows") { model.gitHub != .none }
            model.openGitHubForCode()

            model.cancelGitHubSignIn()
            try await eventually("the sign-in ends") { !model.isSigningIn }
            #expect(model.gitHub == .none)
            #expect(model.gitHubNote == nil)
            #expect(!model.isSigningIn)
            #expect(try Keychain.read(home.keychainItem) == nil)

            Task { await model.connectGitHub() }
            try await eventually("the code shows again") { model.gitHub != .none }
            #expect(!model.isWaitingForGitHub)
            model.cancelGitHubSignIn()
            try await eventually("the sign-in ends") { !model.isSigningIn }
        }
    }

    @Test func backWhileTheLoginIsReadStillEndsTheSignIn() async throws {
        try await withHome(fresh: true) { home in
            let github = GitHubStub()
            await github.answerTheCodeWith(GitHubStub.token)
            await github.holdTheLogin()
            let model = home.model(send: github.send)
            Task { await model.connectGitHub() }
            try await eventually("the login is asked for") { await github.tokens.count == 1 }

            model.cancelGitHubSignIn()
            await github.release()
            try await eventually("the sign-in ends") { !model.isSigningIn }
            #expect(model.gitHub == .none)
            #expect(model.gitHubNote == nil)
            let kept = try Keychain.read(home.keychainItem)
            #expect(kept == nil)
        }
    }

    @Test func aSecondSignInThatEndsLeavesTheConnectionAsItWas() async throws {
        try await withHome { home in
            let github = GitHubStub()
            await github.answerTheCodeWith(#"{"error": "expired_token"}"#)
            let model = home.model(send: github.send, sleep: { _ in try await Task.sleep(for: .seconds(30)) })
            try await ends("the code sign-in ends") { await model.connectGitHub() }
            #expect(model.gitHub == .connected(login: "kd", throughGh: false))
            #expect(model.gitHubNote == "The code expired.")

            Task { await model.connectGitHub() }
            try await eventually("the code shows") { model.gitHub != .connected(login: "kd", throughGh: false) }
            model.cancelGitHubSignIn()
            try await eventually("the sign-in ends") { !model.isSigningIn }
            #expect(model.gitHub == .connected(login: "kd", throughGh: false))
            #expect(Preferences(defaults: home.defaults).gitHubLogin == "kd")
            let kept = try Keychain.read(home.keychainItem)
            #expect(kept == "made-up-token")
        }
    }

    @Test func aSignOutWhileTheCodeShowsEndsTheSignIn() async throws {
        try await withHome { home in
            let github = GitHubStub()
            let model = home.model(send: github.send, sleep: { _ in try await Task.sleep(for: .seconds(30)) })
            Task { await model.connectGitHub() }
            try await eventually("the code shows") { model.gitHub != .connected(login: "kd", throughGh: false) }

            model.signOutOfGitHub()
            try await eventually("the sign-in ends") { !model.isSigningIn }
            #expect(model.gitHub == .none)
        }
    }

    @Test func aSignOutWhileGhsSignInIsAnsweredLeavesGitHubSignedOut() async throws {
        try await withHome { home in
            let github = GitHubStub()
            let model = home.model(findTool: Fake.found(["gh": try Fake.gh()]), send: github.send)
            model.start()
            try await eventually("the first refresh ends") { await github.requests > 0 && !model.isRefreshing }
            await github.holdTheLogin()
            Task { await model.useGhSignIn() }
            try await eventually("the login is asked for") { await github.isHolding }

            model.signOutOfGitHub()
            await github.release()
            try await eventually("the sign-in ends") { !model.isSigningIn }
            #expect(model.gitHub == .none)
            #expect(model.gitHubNote == nil)
            #expect(Preferences(defaults: home.defaults).gitHubLogin == nil)
            #expect(!Preferences(defaults: home.defaults).usesGhSignIn)
        }
    }

    @Test func aSignOutOfGitHubLeavesAToolsSignInRunning() async throws {
        try await withHome { home in
            let model = home.model(findTool: Fake.found(["codex": try Fake.codex()]))
            model.start()
            Task { await model.addAccount(.codex) }
            try await eventually("the browser is waited for") { model.signInStep[.codex] == .waitingForBrowser }

            model.signOutOfGitHub()
            try await Task.sleep(for: .milliseconds(100))  // a sign-in the sign-out cancelled would have ended by now
            #expect(model.signInStep[.codex] == .waitingForBrowser)
            #expect(model.isSigningIn)
            model.cancelSignIn(.codex)
            try await eventually("the sign-in ends") { !model.isSigningIn }
        }
    }

    @Test func aSignOutBeforeTheCodeArrivesLeavesGitHubSignedOut() async throws {
        try await withHome { home in
            let github = GitHubStub()
            await github.holdTheCode()
            let model = home.model(send: github.send, sleep: { _ in try await Task.sleep(for: .seconds(30)) })
            Task { await model.connectGitHub() }
            try await eventually("the code is asked for") { await github.isHolding }

            model.signOutOfGitHub()
            await github.release()
            try await eventually("the answer is taken") { !model.isSigningIn || model.gitHub != .none }
            #expect(model.gitHub == .none)
            #expect(!model.isSigningIn)
            model.cancelGitHubSignIn()
            try await eventually("the sign-in ends") { !model.isSigningIn }
        }
    }

    @Test func ghsSignInConnectsAndKeepsNothing() async throws {
        try await withHome(fresh: true) { home in
            let github = GitHubStub()
            let model = home.model(findTool: Fake.found(["gh": try Fake.gh()]), send: github.send)
            #expect(!model.canUseGh)
            model.panelOpened()
            try await eventually("gh is found signed in") { model.canUseGh }
            try await eventually("the reading says signed out") { model.snapshot.pullRequests.trouble == .signedOut }
            try await home.settled()
            try #require(model.needsGitHubSignIn)

            await github.holdNext()
            try await ends("gh's sign-in ends") { await model.useGhSignIn() }
            #expect(model.gitHub == .connected(login: "kd", throughGh: true))
            #expect(!model.needsGitHubSignIn, "before the pull requests are read again")
            #expect(model.snapshot.pullRequests.detail == nil)
            #expect(model.gitHubNote == nil)
            #expect(try Keychain.read(home.keychainItem) == nil)
            #expect(Preferences(defaults: home.defaults).gitHubLogin == "kd")
            #expect(Preferences(defaults: home.defaults).usesGhSignIn)

            try await eventually("the pull requests are asked for") { await github.requests == 1 }
            await github.release()
            try await eventually("the pull requests are read") { model.list.openCount == 1 }
            #expect(Set(await github.tokens) == ["bearer gho_fromgh"])
            #expect(model.canUseGh, "GitHub took the token gh gave")
        }
    }

    @Test func switchingToGhsSignInForgetsTheKeptOne() async throws {
        try await withHome { home in
            let github = GitHubStub()
            Preferences(defaults: home.defaults).isSetUp = false
            let model = home.model(findTool: Fake.found(["gh": try Fake.gh()]), send: github.send)
            model.panelOpened()
            try await eventually("gh is found signed in") { model.canUseGh }

            try await ends("gh's sign-in ends") { await model.useGhSignIn() }
            #expect(model.gitHub == .connected(login: "kd", throughGh: true))
            let kept = try Keychain.read(home.keychainItem)
            #expect(kept == nil)
        }
    }

    @Test func aSwitchToGhThatFailsKeepsTheCodeSignIn() async throws {
        try await withHome { home in
            let model = home.model(findTool: Fake.found(["gh": try Fake.gh(signedIn: false)]))
            model.start()
            try await ends("gh's sign-in ends") { await model.useGhSignIn() }
            #expect(model.gitHub == .connected(login: "kd", throughGh: false))
            #expect(model.gitHubNote == "GitHub sign-in is missing or no longer valid.")
            let kept = try Keychain.read(home.keychainItem)
            #expect(kept == "made-up-token")
            #expect(!Preferences(defaults: home.defaults).usesGhSignIn)
        }
    }

    @Test func ghWithoutASignInIsNotOffered() async throws {
        try await withHome(fresh: true) { home in
            let model = home.model(findTool: Fake.found(["gh": try Fake.gh(signedIn: false)]))
            model.panelOpened()
            try await eventually("the lookup ends") { !model.existingSignIns.isEmpty }
            #expect(!model.canUseGh)

            try await ends("gh's sign-in ends") { await model.useGhSignIn() }
            #expect(model.gitHub == .none)
            #expect(model.gitHubNote == "GitHub sign-in is missing or no longer valid.")
        }
    }

    @Test func aGhThatCannotStartIsNotOffered() async throws {
        try await withHome(fresh: true) { home in
            let model = home.model(findTool: Fake.found(["gh": URL(filePath: "/nowhere/gh")]))
            model.panelOpened()
            try await eventually("the lookup ends") { !model.existingSignIns.isEmpty }
            #expect(!model.canUseGh)
        }
    }

    @Test func aGhSignInThatGitHubRefusesIsNotOfferedAgain() async throws {
        try await withHome(fresh: true) { home in
            let github = GitHubStub()
            await github.refuseTokens()
            let gh = try Fake.gh()
            let model = home.model(findTool: Fake.found(["gh": gh]), send: github.send)
            model.panelOpened()
            try await eventually("gh is found signed in") { model.canUseGh }

            try await ends("gh's sign-in ends") { await model.useGhSignIn() }
            #expect(model.gitHub == .none)
            #expect(model.gitHubNote == "GitHub sign-in is missing or no longer valid.")
            #expect(!model.canUseGh)

            model.findSignIns()
            try await eventually("gh is asked again") { (try? Fake.timesAsked(gh)) == 3 }
            try await Task.sleep(for: .milliseconds(100))  // a lookup that offered gh again would have done so by now
            #expect(!model.canUseGh)
        }
    }

    @Test func aRefreshThroughGhThatGitHubRefusesStopsOfferingGh() async throws {
        try await withHome { home in
            Preferences(defaults: home.defaults).usesGhSignIn = true
            let github = GitHubStub()
            await github.refuseTokens()
            let gh = try Fake.gh()
            let model = home.model(findTool: Fake.found(["gh": gh]), send: github.send)
            model.findSignIns()
            try await eventually("gh is found signed in") { model.canUseGh }

            try await ends("the refresh ends") { await model.refresh(.all) }
            #expect(model.snapshot.pullRequests.trouble == .signedOut)
            #expect(model.needsGitHubSignIn)
            #expect(!model.canUseGh)

            model.findSignIns()
            try await eventually("gh is asked again") { (try? Fake.timesAsked(gh)) == 3 }
            try await Task.sleep(for: .milliseconds(100))  // a lookup that offered gh again would have done so by now
            #expect(!model.canUseGh)
        }
    }

    @Test func aGhWithNoSignInLeftIsOfferedAgainOnceItHasOne() async throws {
        try await withHome(fresh: true) { home in
            let github = GitHubStub()
            let gh = try Fake.gh()
            let signedOut = try Fake.gh(signedIn: false)
            let since = Fake.beside(gh, "signed-out")
            let model = home.model(
                findTool: { name in
                    guard name == "gh" else { return nil }
                    return FileManager.default.fileExists(atPath: since.path) ? signedOut : gh
                }, send: github.send)
            model.panelOpened()
            try await eventually("gh is found signed in") { model.canUseGh }

            try Data().write(to: since)
            model.findSignIns()
            try await eventually("gh is found signed out") { !model.canUseGh }
            try await ends("gh's sign-in ends") { await model.useGhSignIn() }
            try #require(model.gitHubNote == "GitHub sign-in is missing or no longer valid.")

            try FileManager.default.removeItem(at: since)
            model.findSignIns()
            try await eventually("gh is offered again: GitHub refused nothing") { model.canUseGh }
        }
    }

    @Test func atLaunchTheConnectionIsWhatWasRemembered() async throws {
        try await withHome(fresh: true) { home in
            #expect(home.model().gitHub == .none)

            let preferences = Preferences(defaults: home.defaults)
            preferences.gitHubLogin = "kd"
            #expect(home.model().gitHub == .connected(login: "kd", throughGh: false))

            preferences.usesGhSignIn = true
            #expect(home.model().gitHub == .connected(login: "kd", throughGh: true))
        }
    }

    @Test func aSignInMissingFromTheKeychainShowsAsSignedOut() async throws {
        try await withHome { home in
            let github = GitHubStub()
            try Keychain.delete(home.keychainItem)
            let model = home.model(send: github.send)
            #expect(!model.needsGitHubSignIn)

            try await ends("the refresh ends") { await model.refresh(.all) }
            #expect(model.snapshot.pullRequests.trouble == .signedOut)
            #expect(model.needsGitHubSignIn)
            #expect(await github.requests == 0)
        }
    }

    @Test func signingOutForgetsTheSignInAndEmptiesTheLists() async throws {
        try await withHome { home in
            Preferences(defaults: home.defaults).usesGhSignIn = true
            let model = home.model(snapshot: stage("day"))
            try #require(model.list.openCount == 7)
            try await ends("the code sign-in ends") { await model.connectGitHub() }
            try #require(model.gitHubNote == "GitHub could not be reached.")

            model.signOutOfGitHub()
            #expect(model.gitHub == .none)
            #expect(model.gitHubNote == nil)
            #expect(model.needsGitHubSignIn)
            #expect(try Keychain.read(home.keychainItem) == nil)
            #expect(Preferences(defaults: home.defaults).gitHubLogin == nil)
            #expect(!Preferences(defaults: home.defaults).usesGhSignIn)
            #expect(model.list.openCount == 0)
            #expect(model.snapshot.pullRequests == Snapshot.empty.pullRequests)
            #expect(model.snapshot.accounts == stage("day").accounts)
            #expect(SavedSnapshot.read(from: home.files.snapshot) == model.snapshot)
        }
    }

    @Test func aSignOutDuringARefreshKeepsTheListsEmpty() async throws {
        try await withHome { home in
            let github = GitHubStub()
            let model = home.model(send: github.send)
            await github.holdNext()
            Task { await model.refresh(.all) }
            try await eventually("GitHub is asked") { await github.requests == 1 }

            model.signOutOfGitHub()
            await github.release()
            try await eventually("the refresh ends") { !model.isRefreshing }
            #expect(model.list.openCount == 0)
            #expect(model.snapshot.pullRequests == Snapshot.empty.pullRequests)
        }
    }

    @Test(arguments: hidden) func hiddenOrganizationsAreNamed(names: [String], note: String?) async throws {
        try await withHome { home in
            var snapshot = Snapshot.empty
            snapshot.pullRequests.value.hiddenOrganizations = names
            #expect(home.model(snapshot: snapshot).hiddenOrganizationsNote == note)
        }
    }

    @Test func gitHubNeedsASignInWhenItHasNoneOrItStoppedWorking() async throws {
        try await withHome { home in
            var snapshot = Snapshot.empty
            #expect(!home.model(snapshot: snapshot).needsGitHubSignIn)

            snapshot.pullRequests.trouble = .offline
            #expect(!home.model(snapshot: snapshot).needsGitHubSignIn)

            snapshot.pullRequests.trouble = .signedOut
            #expect(home.model(snapshot: snapshot).needsGitHubSignIn)

            Preferences(defaults: home.defaults).gitHubLogin = nil
            #expect(home.model().needsGitHubSignIn)
        }
    }
}
