import Foundation
import Observation
import SandbarCore
import SandbarTestSupport
import SandbarUI
import Testing

@Suite(.serialized) struct ToolAccountTests {
    @Test func aToolSignedInOnThisMacCanBeUsed() async throws {
        try await withHome(fresh: true) { home in
            let model = home.model(findTool: Fake.found(["claude": try Fake.claude(ownSignIn: true)]))
            #expect(model.existingSignIns.isEmpty)
            #expect(!model.canUseExisting(.claude))

            model.panelOpened()
            try await eventually("the lookup ends") { !model.existingSignIns.isEmpty }
            #expect(model.existingSignIns == [.claude: .usable, .codex: .absent])
            #expect(model.canUseExisting(.claude))
            #expect(!model.canUseExisting(.codex))
        }
    }

    @Test func aToolThatIsSignedOutOrCannotSayIsNotOffered() async throws {
        try await withHome(fresh: true) { home in
            let silent = try FakeTool.script(named: "claude", "printf hello")
            let model = home.model(findTool: Fake.found(["claude": silent, "codex": try Fake.codex()]))
            model.panelOpened()
            try await eventually("the lookup ends") { !model.existingSignIns.isEmpty }
            #expect(
                model.existingSignIns == [
                    .claude: .unreadable("Claude Code's answer was not understood."), .codex: .absent,
                ])
            #expect(!model.canUseExisting(.claude))
        }
    }

    @Test func signInsAreLookedForOnlyWhileASignInIsOnScreenOrWhenAsked() async throws {
        let counting = #"""
            echo "$*" >> "$(dirname "$0")/asked"
            if [ -e "$(dirname "$0")/signed-out" ]; then echo '{"loggedIn": false}'; else echo '{"loggedIn": true}'; fi
            """#
        func asked(_ claude: URL) throws -> Int {
            let record = Fake.beside(claude, "asked")
            guard FileManager.default.fileExists(atPath: record.path) else { return 0 }
            return try String(contentsOf: record, encoding: .utf8).split(separator: "\n").count
        }
        try await withHome { home in
            let claude = try FakeTool.script(named: "claude", counting)
            let model = home.model(findTool: Fake.found(["claude": claude]))
            model.start()
            model.panelOpened()
            try await Task.sleep(for: .milliseconds(100))
            #expect(model.existingSignIns.isEmpty, "after setup, with GitHub connected, nothing is looked for")

            try Data().write(to: Fake.beside(claude, "signed-out"))
            model.findSignIns()
            try await eventually("the lookup that was asked for ends") { model.existingSignIns[.claude] == .absent }
            #expect(try asked(claude) == 1, "only the lookup that was asked for")
        }
        try await withHome { home in
            var stoppedWorking = Snapshot.empty
            stoppedWorking.pullRequests.trouble = .signedOut
            try SavedSnapshot.write(stoppedWorking, to: home.files.snapshot)
            let claude = try FakeTool.script(named: "claude", counting)
            let model = home.model(findTool: Fake.found(["claude": claude]))
            model.start()
            model.panelOpened()
            try await eventually("both lookups end") { (try? asked(claude)) == 2 }
        }
        try await withHome(fresh: true) { home in
            let claude = try FakeTool.script(named: "claude", counting)
            let model = home.model(findTool: Fake.found(["claude": claude]))
            model.start()
            model.panelOpened()
            try await eventually("both lookups end") { (try? asked(claude)) == 2 }
        }
    }

    @Test func usingTheExistingSignInSavesAnAccountWithoutAProfile() async throws {
        try await withHome(fresh: true) { home in
            let model = home.model(findTool: Fake.found(["claude": try Fake.claude(ownSignIn: true)]))
            model.start()
            try await eventually("the sign-in is found") { model.canUseExisting(.claude) }

            try await ends("the sign-in on this Mac is taken or refused") { await model.useExisting(.claude) }
            let account = try #require(model.accounts.first)
            #expect(model.accounts.count == 1)
            #expect(account.tool == .claude)
            #expect(account.title == "Acme Robotics (Enterprise)")
            #expect(account.profile == nil)
            #expect(model.signInStep[.claude] == .idle)
            #expect(try Account.load(from: home.files.accounts) == [account])
            #expect(!model.canUseExisting(.claude))
            #expect(try entries(of: home.files.profiles).isEmpty)

            try await eventually("the limits are read") {
                model.snapshot.accounts.first?.limits.value.map(\.label) == ["Week"]
            }
        }
    }

    @Test func aToolThatNamesNoOrganizationGivesItsOwnName() async throws {
        try await withHome { home in
            let model = home.model(findTool: Fake.found(["codex": try Fake.codex(ownSignIn: true)]))
            model.start()
            try await ends("the sign-in on this Mac is taken or refused") { await model.useExisting(.codex) }
            #expect(model.accounts.map(\.title) == ["Codex (Plus)"])
            #expect(model.accounts.first?.profile == nil)
        }
    }

    @Test func usingASignInThatIsGoneFails() async throws {
        try await withHome { home in
            let model = home.model(findTool: Fake.found(["claude": try Fake.claude()]))
            model.start()
            try await ends("the sign-in on this Mac is taken or refused") { await model.useExisting(.claude) }
            #expect(model.accounts.isEmpty)
            #expect(model.signInStep[.claude] == .failed("Signed out."))
            #expect(!FileManager.default.fileExists(atPath: home.files.accounts.path))

            try await ends("the sign-in on this Mac is taken or refused") { await model.useExisting(.codex) }
            #expect(model.signInStep[.codex] == .failed("Codex was not found."))
        }
    }

    @Test func aFailureStaysUntilTheNextAttemptAndASignInThatWorksClearsIt() async throws {
        try await withHome(fresh: true) { home in
            let signedIn = try Fake.claude(ownSignIn: true)
            let signedOut = try Fake.claude()
            let since = Fake.beside(signedIn, "since")
            let model = home.model(findTool: { name in
                guard name == "claude" else { return nil }
                return FileManager.default.fileExists(atPath: since.path) ? signedIn : signedOut
            })
            model.panelOpened()
            try await eventually("the lookup ends") { !model.existingSignIns.isEmpty }
            try await ends("the sign-in on this Mac is taken or refused") { await model.useExisting(.claude) }
            try #require(model.signInStep[.claude] == .failed("Signed out."))

            try Data().write(to: since)
            model.panelOpened()
            try await eventually("the sign-in is found") { model.canUseExisting(.claude) }
            #expect(model.signInStep[.claude] == .failed("Signed out."), "looking again clears nothing")

            try await ends("the sign-in on this Mac is taken or refused") { await model.useExisting(.claude) }
            #expect(model.signInStep[.claude] == .idle)
            #expect(model.accounts.count == 1)
        }
    }

    @Test func addingACodexAccountSignsInThroughTheBrowser() async throws {
        try await withHome { home in
            let codex = try Fake.codex(afterStart: Fake.finishedInTheBrowser)
            let opened = Opened()
            let model = home.model(
                findTool: Fake.found(["codex": codex]), openAddress: { opened.addresses.append($0) })
            model.start()

            Task { await model.addAccount(.codex) }
            try await eventually("the browser is waited for") {
                model.signInStep[.codex] == .waitingForBrowser && !opened.addresses.isEmpty
            }
            #expect(model.isSigningIn)
            #expect(model.isChangingAccounts)
            #expect(opened.addresses == [Fake.codexAddress])
            #expect(model.accounts.isEmpty)
            let profile = try #require(try entries(of: home.files.profiles).first)

            model.openSignInAgain()
            #expect(opened.addresses == [Fake.codexAddress, Fake.codexAddress])

            try Fake.answerInTheBrowser("approved", for: codex)
            try await eventually("the sign-in ends") { !model.isSigningIn }
            let account = try #require(model.accounts.first)
            #expect(account.title == "Acme Robotics (Team)")
            #expect(account.profile?.lastPathComponent == profile)
            #expect(account.profile?.deletingLastPathComponent().path == home.files.profiles.path)
            #expect(model.signInStep[.codex] == .idle)
            #expect(!model.isSigningIn)
            #expect(try Account.load(from: home.files.accounts) == [account])

            model.openSignInAgain()
            #expect(opened.addresses.count == 2)
            try await eventually("the limits are read") {
                model.snapshot.accounts.first?.limits.value.map(\.label) == ["5h"]
            }
        }
    }

    @Test func aFailedSignInLeavesNoProfileAndNoAccount() async throws {
        try await withHome { home in
            let codex = try Fake.codex(afterStart: Fake.finishedInTheBrowser)
            let model = home.model(findTool: Fake.found(["codex": codex]))
            model.start()
            Task { await model.addAccount(.codex) }
            try await eventually("the browser is waited for") { model.signInStep[.codex] == .waitingForBrowser }
            try #require(try entries(of: home.files.profiles).count == 1)

            try Fake.answerInTheBrowser("denied", for: codex)
            try await eventually("the sign-in ends") { !model.isSigningIn }
            #expect(model.signInStep[.codex] == .failed("denied"))
            #expect(model.accounts.isEmpty)
            #expect(try entries(of: home.files.profiles).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: home.files.accounts.path))
            #expect(!model.isSigningIn)
        }
    }

    @Test func aCancelledSignInLeavesNoProfile() async throws {
        try await withHome { home in
            let codex = try Fake.codex()
            let model = home.model(findTool: Fake.found(["claude": try Fake.claude(), "codex": codex]))
            model.start()
            for tool in Tool.allCases {
                Task { await model.addAccount(tool) }
                try await eventually("the browser is waited for") { model.signInStep[tool] == .waitingForBrowser }
                try #require(try entries(of: home.files.profiles).count == 1)

                model.cancelSignIn(tool == .claude ? .codex : .claude)
                try await Task.sleep(for: .milliseconds(100))
                #expect(model.signInStep[tool] == .waitingForBrowser, "another tool's Cancel ends nothing")
                #expect(model.isSigningIn)

                model.cancelSignIn(tool)
                try await eventually("the sign-in ends") { !model.isSigningIn }
                #expect(model.signInStep[tool] == .idle)
                #expect(model.accounts.isEmpty)
                #expect(try entries(of: home.files.profiles).isEmpty)
                #expect(!model.isSigningIn)
            }
            try await eventually("Codex hears of it") {
                FileManager.default.fileExists(atPath: Fake.beside(codex, "cancelled").path)
            }
        }
    }

    @Test func aPastedCodeReachesClaudeAndFinishesTheSignIn() async throws {
        try await withHome { home in
            let opened = Opened()
            let model = home.model(
                findTool: Fake.found(["claude": try Fake.claude()]), openAddress: { opened.addresses.append($0) })
            model.start()
            Task { await model.addAccount(.claude) }
            try await eventually("the browser is waited for") { model.signInStep[.claude] == .waitingForBrowser }
            #expect(opened.addresses.isEmpty, "Claude Code opens its own page")
            try await eventually("the address is read") {
                model.openSignInAgain()
                return !opened.addresses.isEmpty
            }
            #expect(opened.addresses.first == Fake.claudeAddress)

            model.pasteCode(" code-123\n")
            try await eventually("the sign-in ends") { !model.isSigningIn }
            let account = try #require(model.accounts.first)
            #expect(account.title == "Acme Robotics (Enterprise)")
            let profile = try #require(account.profile)
            #expect(FileManager.default.fileExists(atPath: profile.appending(path: "signed-in").path))
            #expect(model.signInStep[.claude] == .idle)
        }
    }

    @Test func aCodePastedTheMomentTheFieldShowsReachesClaude() async throws {
        try await withHome { home in
            let model = home.model(findTool: Fake.found(["claude": try Fake.claude()]))
            model.start()
            paste("code-123", whenTheFieldShowsIn: model)
            Task { await model.addAccount(.claude) }
            try await eventually("the account is saved") { model.accounts.count == 1 }
        }
    }

    private func paste(_ code: String, whenTheFieldShowsIn model: AppModel) {
        withObservationTracking {
            _ = model.signInStep
        } onChange: {
            Task { @MainActor in
                if model.signInStep[.claude] == .waitingForBrowser {
                    model.pasteCode(code)
                } else {
                    paste(code, whenTheFieldShowsIn: model)
                }
            }
        }
    }

    @Test func aWrongCodeFailsTheSignIn() async throws {
        try await withHome { home in
            let model = home.model(findTool: Fake.found(["claude": try Fake.claude()]))
            model.start()
            Task { await model.addAccount(.claude) }
            try await eventually("the browser is waited for") { model.signInStep[.claude] == .waitingForBrowser }
            model.pasteCode("another-code")
            try await eventually("the sign-in ends") { !model.isSigningIn }
            #expect(model.signInStep[.claude] == .failed("Claude Code ended with status 1."))
            #expect(model.accounts.isEmpty)
            #expect(try entries(of: home.files.profiles).isEmpty)

            model.pasteCode("code-123")
            #expect(model.accounts.isEmpty, "a code pasted after the sign-in ended goes nowhere")
        }
    }

    @Test func aCodeTheToolNoLongerReadsEndsTheSignIn() async throws {
        try await withHome { home in
            let deaf = try FakeTool.script(
                named: "claude", #"[ "$*" = "auth login" ] && { exec <&-; touch "$(dirname "$0")/deaf"; sleep 15; }"#)
            let model = home.model(findTool: Fake.found(["claude": deaf]))
            model.start()
            Task { await model.addAccount(.claude) }
            try await eventually("the tool stops reading") {
                FileManager.default.fileExists(atPath: Fake.beside(deaf, "deaf").path)
            }
            try #require(model.signInStep[.claude] == .waitingForBrowser)

            model.pasteCode("code-123")
            try await eventually("the sign-in ends") { !model.isSigningIn }
            guard case .failed = model.signInStep[.claude] else {
                Issue.record("expected a failure, got \(String(describing: model.signInStep[.claude]))")
                return
            }
            #expect(model.accounts.isEmpty)
        }
    }

    @Test func endingASignInWaitsUntilItsProgramHasEnded() async throws {
        try await withHome { home in
            let runsOn = try FakeTool.script(
                named: "claude",
                #"""
                [ "$*" = "auth login" ] || exit 1
                echo $$ > "$(dirname "$0")/pid"
                trap 'sleep 0.3; exit 1' TERM
                sleep 15 &
                wait $!
                """#)
            let model = home.model(findTool: Fake.found(["claude": runsOn]))
            model.start()
            Task { await model.addAccount(.claude) }
            var program: Int32?
            try await eventually("the sign-in's program runs") {
                program = (try? String(contentsOf: Fake.beside(runsOn, "pid"), encoding: .utf8))
                    .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                return program != nil && model.signInStep[.claude] == .waitingForBrowser
            }

            try await ends("the sign-in is ended") { await model.endSignIn() }
            let hasEnded = kill(try #require(program), 0) == -1 && errno == ESRCH
            #expect(hasEnded)
            #expect(try entries(of: home.files.profiles).isEmpty)
            try await eventually("the sign-in ends") { !model.isSigningIn }
            #expect(model.signInStep[.claude] == .idle)
        }
    }

    @Test func oneSignInRunsAtATime() async throws {
        try await withHome(fresh: true) { home in
            let github = GitHubStub()
            let model = home.model(
                findTool: Fake.found(["claude": try Fake.claude(ownSignIn: true), "codex": try Fake.codex()]),
                send: github.send)
            model.start()
            Task { await model.addAccount(.codex) }
            try await eventually("the browser is waited for") { model.signInStep[.codex] == .waitingForBrowser }

            try await ends("a second sign-in is turned away at once") { await model.addAccount(.claude) }
            try await ends("a second sign-in is turned away at once") { await model.useExisting(.claude) }
            try await ends("a second sign-in is turned away at once") { await model.connectGitHub() }
            #expect(model.signInStep[.claude] == .idle)
            #expect(model.accounts.isEmpty)
            #expect(model.gitHub == .none)
            #expect(try entries(of: home.files.profiles).count == 1)

            model.cancelSignIn(.codex)
            try await eventually("the sign-in ends") { !model.isSigningIn }
        }
    }

    @Test func removingAnAccountSignsItOutAndDeletesItsProfile() async throws {
        try await withHome { home in
            let claude = try Fake.claude(ownSignIn: true)
            let added = Account(
                tool: .claude, name: "Work", plan: "Enterprise",
                profile: try Account.makeProfile(in: home.files.profiles))
            let own = Account(tool: .claude, name: "Personal", plan: "Max", profile: nil)
            try Account.save([added, own], to: home.files.accounts)
            let model = home.model(findTool: Fake.found(["claude": claude]))
            model.start()
            try await eventually("both accounts are read") { model.snapshot.accounts.count == 2 }
            try await home.settled()
            let profile = try #require(added.profile)

            try await ends("the account is removed or kept") { await model.remove(added) }
            #expect(model.accounts == [own])
            #expect(!FileManager.default.fileExists(atPath: profile.path))
            let signedOut = try String(contentsOf: Fake.beside(claude, "signed-out"), encoding: .utf8)
            #expect(signedOut.hasSuffix("/\(profile.lastPathComponent)\n"))
            #expect(try Account.load(from: home.files.accounts) == [own])
            try await eventually("the limits no longer hold it") { model.snapshot.accounts.map(\.account) == [own] }

            try FileManager.default.removeItem(at: Fake.beside(claude, "signed-out"))
            try await ends("the account is removed or kept") { await model.remove(own) }
            #expect(model.accounts.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: Fake.beside(claude, "signed-out").path))
            #expect(try Account.load(from: home.files.accounts).isEmpty)
            try await eventually("the limits hold no account") { model.snapshot.accounts.isEmpty }
        }
    }

    @Test func aRemoveWhoseSignOutFailsKeepsTheAccountAndSaysWhy() async throws {
        try await withHome { home in
            let added = Account(
                tool: .claude, name: "Work", plan: "Enterprise",
                profile: try Account.makeProfile(in: home.files.profiles))
            try Account.save([added], to: home.files.accounts)
            let refusing = try FakeTool.script(
                named: "claude",
                #"""
                case "$*" in
                  "auth logout") echo refused >&2; exit 1 ;;
                  "auth status") echo '{"loggedIn": false}'; exit 1 ;;
                esac
                """#)
            let model = home.model(findTool: Fake.found(["claude": refusing]))
            model.start()
            try await eventually("the account is read") { model.snapshot.accounts.count == 1 }
            try await home.settled()

            try await ends("the account is removed or kept") { await model.remove(added) }
            #expect(model.accounts == [added])
            #expect(model.signInStep[.claude] == .failed("refused"))
            #expect(FileManager.default.fileExists(atPath: try #require(added.profile).path))
            #expect(try Account.load(from: home.files.accounts) == [added])
        }
    }

    @Test func withNoToolAnywhereAnAccountIsRemovedWithoutASignOut() async throws {
        try await withHome { home in
            let added = Account(
                tool: .codex, name: "Work", plan: "Team", profile: try Account.makeProfile(in: home.files.profiles))
            try Account.save([added], to: home.files.accounts)
            let model = home.model()
            model.start()
            try await eventually("the account is read") { model.snapshot.accounts.count == 1 }
            try await home.settled()

            try await ends("the account is removed or kept") { await model.remove(added) }
            #expect(model.accounts.isEmpty)
            #expect(model.signInStep[.codex] == .idle)
            #expect(!FileManager.default.fileExists(atPath: try #require(added.profile).path))
            #expect(try Account.load(from: home.files.accounts).isEmpty)
        }
    }

    @Test func removingDoesNothingWhileASignInRuns() async throws {
        try await withHome { home in
            let added = Account(
                tool: .codex, name: "Work", plan: "Team", profile: try Account.makeProfile(in: home.files.profiles))
            try Account.save([added], to: home.files.accounts)
            let codex = try Fake.codex()
            let model = home.model(findTool: Fake.found(["codex": codex]))
            model.start()
            try await eventually("the account is read") { model.snapshot.accounts.count == 1 }
            Task { await model.addAccount(.codex) }
            try await eventually("the browser is waited for") { model.signInStep[.codex] == .waitingForBrowser }

            try await ends("the remove is turned away") { await model.remove(added) }
            #expect(model.accounts == [added])
            #expect(model.signInStep[.codex] == .waitingForBrowser)
            #expect(FileManager.default.fileExists(atPath: try #require(added.profile).path))
            #expect(!FileManager.default.fileExists(atPath: Fake.beside(codex, "signed-out").path))

            model.cancelSignIn(.codex)
            try await eventually("the sign-in ends") { !model.isSigningIn }
            #expect(model.accounts == [added])
        }
    }

    @Test func aSignInAskedForWhileARemoveWaitsDoesNotStart() async throws {
        try await withHome { home in
            let added = Account(
                tool: .claude, name: "Work", plan: "Enterprise",
                profile: try Account.makeProfile(in: home.files.profiles))
            try Account.save([added], to: home.files.accounts)
            let slow = try FakeTool.script(
                named: "claude",
                #"""
                case "$*" in
                  "auth logout") touch "$(dirname "$0")/signing-out"; sleep 0.3; echo refused >&2; exit 1 ;;
                  "auth status") echo '{"loggedIn": false}'; exit 1 ;;
                esac
                """#)
            let model = home.model(findTool: Fake.found(["claude": slow]))
            model.start()
            try await eventually("the account is read") { model.snapshot.accounts.count == 1 }
            try await home.settled()

            Task { await model.remove(added) }
            try await eventually("the tool is signing out") {
                FileManager.default.fileExists(atPath: Fake.beside(slow, "signing-out").path)
            }
            #expect(model.isChangingAccounts)
            #expect(!model.isSigningIn, "a remove is no sign-in")

            try await ends("the sign-in is turned away at once") { await model.addAccount(.claude) }
            try await ends("there is no sign-in to end") { await model.endSignIn() }
            #expect(model.signInStep[.claude] == .idle)
            #expect(try entries(of: home.files.profiles).count == 1)

            try await eventually("the remove ends") { !model.isChangingAccounts }
            #expect(model.signInStep[.claude] == .failed("refused"), "written over nothing")
            #expect(model.accounts == [added])
        }
    }

    @Test func renamingSavesTheNewName() async throws {
        try await withHome { home in
            let work = Account(tool: .claude, name: "Acme Robotics", plan: "Enterprise", profile: nil)
            try Account.save([work], to: home.files.accounts)
            let claude = try Fake.claude(ownSignIn: true)
            let installed = Fake.beside(claude, "installed")
            let model = home.model(findTool: { name in
                name == "claude" && FileManager.default.fileExists(atPath: installed.path) ? claude : nil
            })
            model.start()
            try await eventually("the account is read") { model.snapshot.accounts.count == 1 }
            try await home.settled()
            try #require(model.snapshot.accounts.first?.limits.trouble == .toolMissing)

            try Data().write(to: installed)
            model.rename(work, to: "Work")
            #expect(model.accounts.map(\.title) == ["Work (Enterprise)"])
            #expect(model.accounts.first?.id == work.id)
            #expect(try Account.load(from: home.files.accounts).map(\.name) == ["Work"])
            try await eventually("the usage row has the new name, read through the tool found since") {
                model.snapshot.accounts.map(\.account.name) == ["Work"]
                    && model.snapshot.accounts.first?.limits.value.map(\.label) == ["Week"]
            }
        }
    }

    @Test func aSaveThatFailsSaysSoUntilASaveWorks() async throws {
        try await withHome { home in
            let model = home.model(findTool: Fake.found(["claude": try Fake.claude(ownSignIn: true)]))
            model.start()
            try FileManager.default.createDirectory(
                at: home.files.accounts.appending(path: "a folder where the file belongs"),
                withIntermediateDirectories: true)

            try await ends("the sign-in on this Mac is taken") { await model.useExisting(.claude) }
            #expect(model.accountsNote == "Accounts could not be saved.")
            #expect(model.accounts.map(\.title) == ["Acme Robotics (Enterprise)"])
            try await eventually("the account is read in this run all the same") {
                model.snapshot.accounts.first?.limits.value.map(\.label) == ["Week"]
            }

            try FileManager.default.removeItem(at: home.files.accounts)
            model.rename(try #require(model.accounts.first), to: "Work")
            #expect(model.accountsNote == nil)
            #expect(try Account.load(from: home.files.accounts).map(\.name) == ["Work"])
        }
    }

    @Test func anUnreadableAccountsFileIsMovedAsideWithItsNote() async throws {
        try await withHome { home in
            try Data("an older unreadable file".utf8).write(to: home.files.unreadableAccounts)
            try Data("not accounts".utf8).write(to: home.files.accounts)
            let model = home.model(findTool: Fake.found(["claude": try Fake.claude(ownSignIn: true)]))
            #expect(model.accountsNote == nil)

            model.start()
            #expect(model.accounts.isEmpty)
            #expect(model.accountsNote == "Saved accounts could not be read.")
            #expect(!FileManager.default.fileExists(atPath: home.files.accounts.path))
            #expect(try String(contentsOf: home.files.unreadableAccounts, encoding: .utf8) == "not accounts")

            try await ends("the sign-in on this Mac is taken or refused") { await model.useExisting(.claude) }
            #expect(try Account.load(from: home.files.accounts).map(\.title) == ["Acme Robotics (Enterprise)"])
            #expect(model.accountsNote == "Saved accounts could not be read.")
        }
    }

    @Test func anAccountsFileThatCannotBeMovedAsideIsNeverWrittenOver() async throws {
        try await withHome { home in
            try Data("not accounts".utf8).write(to: home.files.accounts)
            let folder = home.files.accounts.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
            defer {
                #expect(throws: Never.self) {
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
                }
            }
            let model = home.model(
                findTool: Fake.found(["claude": try Fake.claude(ownSignIn: true), "codex": try Fake.codex()]))
            model.start()
            #expect(model.accountsNote == "Saved accounts could not be read.")

            try await ends("the sign-in on this Mac is taken or refused") { await model.useExisting(.claude) }
            try await ends("the sign-in ends") { await model.addAccount(.codex) }
            #expect(model.accounts.isEmpty)
            #expect(model.signInStep[.claude] == .failed("Saved accounts could not be read."))
            #expect(model.signInStep[.codex] == .failed("Saved accounts could not be read."))
            #expect(try String(contentsOf: home.files.accounts, encoding: .utf8) == "not accounts")
        }
    }
}
