import Foundation
import SandbarCore
import SandbarTestSupport
import SandbarUI
import Testing

func withDefaults(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
    let suite = "sandbar-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try await body(defaults)
}

func afterSetup(_ defaults: UserDefaults) -> Preferences {
    let preferences = Preferences(defaults: defaults)
    preferences.isSetUp = true
    preferences.gitHubLogin = "kd"
    return preferences
}

func eventually(_ what: Comment, _ isSo: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await isSo()) {
        try #require(ContinuousClock.now < deadline, what)
        try await Task.sleep(for: .milliseconds(2))
    }
}

@MainActor func ends(_ what: Comment, _ work: @escaping @MainActor () async -> Void) async throws {
    @MainActor final class Mark {
        var isSet = false
    }
    let ended = Mark()
    Task {
        await work()
        ended.isSet = true
    }
    try await eventually(what) { ended.isSet }
}

actor GitHubStub {
    static let deviceCode = """
        {"device_code": "3584d83530557fdd1f46af8289938c8ef79f9dc5", "user_code": "WDJB-MJHT",
         "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 5}
        """
    static let token = #"{"access_token": "gho_madeup", "token_type": "bearer", "scope": "repo"}"#
    static let pullRequests = """
        {"data": {
          "mine": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": [
            {"id": "PR_41250", "number": 41250, "title": "Read saved carts through one cart reader",
             "url": "https://github.com/acme/storefront/pull/41250", "isDraft": false,
             "createdAt": "2026-11-09T18:00:00Z", "updatedAt": "2026-11-12T16:00:00Z",
             "author": {"login": "kd", "avatarUrl": "https://example.com/faces/kd.png"},
             "repository": {"nameWithOwner": "acme/storefront"},
             "baseRefName": "main", "headRefName": "cart-reader", "reviewDecision": "APPROVED",
             "latestOpinionatedReviews": {"nodes": []}, "isInMergeQueue": false, "stack": null,
             "stackEntry": null,
             "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}]}}]},
          "reviewRequests": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": []}}}
        """

    private(set) var requests = 0
    private(set) var tokens: [String] = []
    private var tokenAnswers: [String] = []
    private var lists = GitHubStub.pullRequests
    private var held: CheckedContinuation<Void, Never>?
    private var holdsNext = false
    private var holdsTheLogin = false
    private var holdsTheCode = false
    private var status = 200

    nonisolated var send: GitHubClient.Send {
        { request in try await self.answer(request) }
    }

    func holdNext() {
        holdsNext = true
    }

    func holdTheLogin() {
        holdsTheLogin = true
    }

    func holdTheCode() {
        holdsTheCode = true
    }

    var isHolding: Bool { held != nil }

    func refuseTokens() {
        status = 401
    }

    func release() {
        held?.resume()
        held = nil
    }

    func answerTheCodeWith(_ answers: String...) {
        tokenAnswers = answers
    }

    func answerPullRequestsWith(_ answer: String) {
        lists = answer
    }

    private func answer(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let address = try #require(request.url)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let answer: String
        switch address.path {
        case "/login/device/code":
            if holdsTheCode {
                holdsTheCode = false
                await withCheckedContinuation { held = $0 }
            }
            answer = Self.deviceCode
        case "/login/oauth/access_token":
            answer = tokenAnswers.isEmpty ? #"{"error": "authorization_pending"}"# : tokenAnswers.removeFirst()
        case _ where body.contains("viewer"):
            tokens.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            if holdsTheLogin {
                holdsTheLogin = false
                await withCheckedContinuation { held = $0 }
            }
            answer = #"{"data": {"viewer": {"login": "kd"}}}"#
        default:
            requests += 1
            tokens.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            if holdsNext {
                holdsNext = false
                await withCheckedContinuation { held = $0 }
            }
            answer = lists
        }
        let response = try #require(
            HTTPURLResponse(url: address, statusCode: status, httpVersion: nil, headerFields: nil))
        return (Data(answer.utf8), response)
    }
}

@MainActor final class Home {
    let defaults: UserDefaults
    let files: AppModel.Files
    let keychainItem = "test-\(UUID().uuidString)"
    private var made: [() -> AppModel?] = []

    static let noDownload: (URL) -> ToolDownload = { folder in
        ToolDownload(
            folder: folder, fetch: { _ in throw URLError(.notConnectedToInternet) },
            download: { _, _ in throw URLError(.notConnectedToInternet) }, sha256: { _ in "" })
    }

    init(defaults: UserDefaults, files: AppModel.Files) {
        self.defaults = defaults
        self.files = files
    }

    func model(
        snapshot: Snapshot = .empty, findTool: @escaping @Sendable (String) async -> URL? = { _ in nil },
        send: @escaping GitHubClient.Send = { _ in throw URLError(.notConnectedToInternet) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in },
        keychain: Keychain.Item? = nil, toolDownload: (URL) -> ToolDownload = Home.noDownload,
        openAddress: @escaping (URL) -> Void = { _ in }
    ) -> AppModel {
        let model = AppModel(
            snapshot: snapshot, preferences: Preferences(defaults: defaults), now: AppModelTests.now, files: files,
            findTool: findTool, send: send, sleep: sleep, keychain: keychain ?? Keychain.Item(named: keychainItem),
            toolDownload: toolDownload, openAddress: openAddress)
        made.append { [weak model] in model }
        return model
    }

    func settled() async throws {
        try await Task.sleep(for: .milliseconds(20))
        try await eventually("every refresh ends") { self.made.allSatisfy { $0()?.isRefreshing != true } }
    }
}

/// A folder, defaults and a Keychain item of their own; unless `fresh`, setup is finished and GitHub is connected as kd.
func withHome(fresh: Bool = false, _ body: @MainActor (Home) async throws -> Void) async throws {
    try await withDefaults { defaults in
        let folder = FileManager.default.temporaryDirectory.appending(path: "sandbar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let home = Home(defaults: defaults, files: AppModel.Files(folder: folder))
        defer { #expect(throws: Never.self) { try Keychain.delete(home.keychainItem) } }
        if !fresh {
            _ = afterSetup(defaults)
            try Keychain.write("made-up-token", as: home.keychainItem)
        }
        try await body(home)
        try await home.settled()  // a refresh still running would write into the folder after it is removed
    }
}

func entries(of folder: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(atPath: folder.path)
}

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
                ? #"echo "$*" >> "$(dirname "$0")/asked"; [ "$1 $2" = "auth token" ] && printf 'gho_fromgh\n'"#
                : "echo 'You are not logged into any GitHub hosts.' >&2; exit 1")
    }

    static func timesAsked(_ program: URL) throws -> Int {
        let record = beside(program, "asked")
        guard FileManager.default.fileExists(atPath: record.path) else { return 0 }
        return try String(contentsOf: record, encoding: .utf8).split(separator: "\n").count
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
