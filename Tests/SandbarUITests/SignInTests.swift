import AppKit
import Observation
import SandbarCore
import SandbarTestSupport
import SandbarUI
import Testing

actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if !isOpen { await withCheckedContinuation { waiting.append($0) } }
    }

    func open() {
        isOpen = true
        for waiter in waiting { waiter.resume() }
        waiting = []
    }
}

@MainActor final class Opened {
    var addresses: [URL] = []
}

enum Fake {
    static let claudeAddress = URL(string: "https://claude.example/oauth/authorize?code=true")!
    static let codexAddress = URL(string: "https://auth.openai.example/oauth/authorize?state=abc")!
    static let finishedInTheBrowser = #"""
        tries=0
        while [ ! -e "$(dirname "$0")/answer" ] && [ $tries -lt 200 ]; do sleep 0.05; tries=$((tries + 1)); done
        if [ "$(cat "$(dirname "$0")/answer")" = approved ]; then
          touch "$CODEX_HOME/auth.json"
          echo '{"method":"account/login/completed","params":{"loginId":"login-1","success":true,"error":null}}'
        else
          echo '{"method":"account/login/completed","params":{"loginId":"login-1","success":false,"error":"denied"}}'
        fi
        """#

    static func found(_ programs: [String: URL]) -> @Sendable (String) async -> URL? {
        { programs[$0] }
    }

    static func gh(signedIn: Bool = true) throws -> URL {
        try FakeTool.script(
            named: "gh",
            signedIn
                ? #"[ "$1 $2" = "auth token" ] && printf 'gho_fromgh\n'"#
                : "echo 'You are not logged into any GitHub hosts.' >&2; exit 1")
    }

    static let usageReport =
        #"echo '{"usage_report":{"rate_limits":{"limits":[{"group":"weekly","percent":37}],"#
        + #""extra_usage":{"is_enabled":false}}}}'"#

    static func claude(ownSignIn: Bool = false, usage: String = usageReport) throws -> URL {
        try FakeTool.script(
            named: "claude",
            #"""
            signed_in=\#(ownSignIn ? "yes" : "no")
            [ -n "$CLAUDE_CONFIG_DIR" ] && signed_in=no
            [ -e "$CLAUDE_CONFIG_DIR/signed-in" ] && signed_in=yes
            case "$*" in
              "auth status")
                if [ $signed_in = yes ]; then
                  echo '{"loggedIn": true, "orgName": "Acme Robotics", "subscriptionType": "enterprise"}'
                else
                  echo '{"loggedIn": false}'
                  exit 1
                fi ;;
              "auth login")
                echo "Opening browser to sign in"
                echo "If the browser didn't open, visit: \#(claudeAddress.absoluteString)"
                IFS= read -r code
                [ "$code" = "code-123" ] || exit 1
                touch "$CLAUDE_CONFIG_DIR/signed-in" ;;
              "auth logout")
                echo "$CLAUDE_CONFIG_DIR" > "$(dirname "$0")/signed-out"
                rm -f "$CLAUDE_CONFIG_DIR/signed-in" ;;
              *) \#(usage) ;;
            esac
            """#)
    }

    static func codex(ownSignIn: Bool = false, afterStart: String = ":") throws -> URL {
        try FakeTool.codexServer(
            answering: #"""
                *'"method":"account/read"'*)
                  account=null
                  [ -z "$CODEX_HOME" ] && account='\#(ownSignIn ? #"{"type":"chatgpt","planType":"plus"}"# : "null")'
                  [ -e "$CODEX_HOME/auth.json" ] &&
                    account='{"type":"chatgpt","planType":"team","workspaceName":"Acme Robotics"}'
                  echo "{\"id\":$id,\"result\":{\"account\":$account,\"requiresOpenaiAuth\":true}}" ;;
                *'"method":"account/login/start"'*)
                  echo "{\"id\":$id,\"result\":{\"type\":\"chatgpt\",\"loginId\":\"login-1\",\"authUrl\":\"\#(codexAddress.absoluteString)\"}}"
                  \#(afterStart) ;;
                *'"method":"account/login/cancel"'*)
                  touch "$(dirname "$0")/cancelled"
                  echo "{\"id\":$id,\"result\":{\"status\":\"canceled\"}}" ;;
                *'"method":"account/logout"'*)
                  echo "$CODEX_HOME" > "$(dirname "$0")/signed-out"
                  rm -f "$CODEX_HOME/auth.json"
                  echo "{\"id\":$id,\"result\":{}}" ;;
                *'"method":"account/rateLimits/read"'*)
                  echo "{\"id\":$id,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":41,\"windowDurationMins\":300}}}}" ;;
                """#)
    }

    static func beside(_ program: URL, _ name: String) -> URL {
        program.deletingLastPathComponent().appending(path: name)
    }

    static func answerInTheBrowser(_ answer: String, for codex: URL) throws {
        try Data(answer.utf8).write(to: beside(codex, "answer"), options: .atomic)
    }

    static func keep(_ program: URL, asSandbarsCopyOf tool: Tool, version: String, in files: AppModel.Files) throws
        -> URL
    {
        let copy = files.tools.appending(path: "\(tool.rawValue)/\(version)/\(program.lastPathComponent)")
        try FileManager.default.createDirectory(
            at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: program, to: copy)
        return copy
    }
}

actor Maker {
    private(set) var asked = 0
    private var version: String
    private var program: URL?
    private let gate: Gate?
    private let stalls: Bool

    init(version: String = "2.1.400", giving program: URL? = nil, gate: Gate? = nil, stalls: Bool = false) {
        self.version = version
        self.program = program
        self.gate = gate
        self.stalls = stalls
    }

    nonisolated var download: (URL) -> ToolDownload {
        { folder in
            ToolDownload(
                folder: folder, fetch: { try await self.answer($0) },
                download: { _, to in try await self.deliver(to) }, sha256: { _ in "aa11" })
        }
    }

    private func answer(_ address: URL) async throws -> Data {
        if address.lastPathComponent == "latest" {
            asked += 1
            await gate?.wait()
            if stalls { try await Task.sleep(for: .seconds(30)) }
            return Data(version.utf8)
        }
        let build = #"{"checksum": "aa11"}"#
        let platforms = ["darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64"].map { #""\#($0)": \#(build)"# }
        return Data(#"{"platforms": {\#(platforms.joined(separator: ", "))}}"#.utf8)
    }

    private func deliver(_ place: URL) throws {
        try FileManager.default.moveItem(at: try #require(program), to: place)
        program = nil
    }
}

@Suite(.serialized) struct SignInTests {
    nonisolated static let endings: [(answer: String, note: String)] = [
        (#"{"error": "expired_token"}"#, "The code expired."),
        (#"{"error": "access_denied"}"#, "The sign-in was cancelled on GitHub."),
    ]
    nonisolated static let hidden: [(names: [String], note: String?)] = [
        ([], nil), (["acme"], "Sandbar cannot see acme."), (["acme", "globex"], "Sandbar cannot see acme and globex."),
    ]

    private func entries(of folder: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path)
    }

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

    @Test func setupIsFinishedOnceAndRemembered() async throws {
        try await withHome(fresh: true) { home in
            let model = home.model()
            #expect(!model.isSetUp)
            model.finishSetup()
            #expect(model.isSetUp)
            #expect(home.model().isSetUp)
        }
    }

    @Test func aShownSnapshotCountsAsSetUpWithNoSignInToAskFor() async throws {
        let model = AppModel(showing: stageFile("day"))
        #expect(model.isSetUp)
        #expect(!model.needsGitHubSignIn)
    }

    @Test func theFooterCountsWhatIsConnected() async throws {
        try await withHome(fresh: true) { home in
            #expect(home.model().setupStatus == "Nothing connected")

            Preferences(defaults: home.defaults).gitHubLogin = "kd"
            #expect(home.model().setupStatus == "1 of 3 connected")

            var snapshot = Snapshot.empty
            snapshot.accounts = [
                Snapshot.AccountLimits(
                    account: Account(tool: .codex, name: "Personal", plan: "Plus", profile: nil),
                    limits: Snapshot.Reading(value: []))
            ]
            #expect(home.model(snapshot: snapshot).setupStatus == "2 of 3 connected")

            snapshot.accounts += [
                Snapshot.AccountLimits(
                    account: Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil),
                    limits: Snapshot.Reading(value: [])),
                Snapshot.AccountLimits(
                    account: Account(tool: .claude, name: "Personal", plan: "Max", profile: nil),
                    limits: Snapshot.Reading(value: [])),
            ]
            #expect(home.model(snapshot: snapshot).setupStatus == "3 of 3 connected")
        }
    }

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
            #expect(model.signInStep[.codex] == .failed("The read failed."))
            let profiles = try entries(of: home.files.profiles)
            #expect(profiles.isEmpty)
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
