import Foundation
import SandbarCore
import SandbarTestSupport
import Testing

struct GitHubSignInTests {
    static let deviceCode = """
        {"device_code": "3584d83530557fdd1f46af8289938c8ef79f9dc5", "user_code": "WDJB-MJHT",
         "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 5}
        """
    static let pending = #"{"error": "authorization_pending"}"#
    static let token = #"{"access_token": "gho_madeup", "token_type": "bearer", "scope": "repo"}"#
    static let failures: [(answer: String, failure: GitHubSignIn.Failure)] = [
        (#"{"error": "expired_token"}"#, .expired), (#"{"error": "access_denied"}"#, .denied),
    ]

    actor Sleeps {
        var durations: [Duration] = []
        func add(_ duration: Duration) { durations.append(duration) }
    }

    let sleeps = Sleeps()

    func signIn(_ exchange: GitHubExchange) -> GitHubSignIn {
        let sleeps = sleeps
        return GitHubSignIn(clientID: "Iv1.made0up", send: exchange.send, sleep: { await sleeps.add($0) })
    }

    @Test func startGivesTheCode() async throws {
        let exchange = GitHubExchange(Self.deviceCode)
        let code = try await signIn(exchange).start()
        #expect(code.userCode == "WDJB-MJHT")
        #expect(code.address == URL(string: "https://github.com/login/device"))
        #expect(code.deviceCode == "3584d83530557fdd1f46af8289938c8ef79f9dc5")
        #expect(code.interval == .seconds(5))
        let request = try #require(await exchange.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == URL(string: "https://github.com/login/device/code"))
        #expect(request.timeoutInterval == 20)
        #expect(try await exchange.form(0) == ["client_id": "Iv1.made0up", "scope": "repo"])
    }

    @Test func pendingWaitsUntilTheToken() async throws {
        let exchange = GitHubExchange(Self.deviceCode, Self.pending, Self.pending, Self.token)
        let signIn = signIn(exchange)
        let token = try await signIn.token(for: try await signIn.start())
        #expect(token == "gho_madeup")
        #expect(await sleeps.durations == [.seconds(5), .seconds(5)])
        let request = await exchange.requests[1]
        #expect(request.url == URL(string: "https://github.com/login/oauth/access_token"))
        #expect(request.timeoutInterval == 20)
        #expect(
            try await exchange.form(1) == [
                "client_id": "Iv1.made0up", "device_code": "3584d83530557fdd1f46af8289938c8ef79f9dc5",
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
    }

    @Test func slowDownAddsFiveSeconds() async throws {
        let slowDown = #"{"error": "slow_down"}"#
        let exchange = GitHubExchange(Self.deviceCode, slowDown, slowDown, Self.token)
        let signIn = signIn(exchange)
        _ = try await signIn.token(for: try await signIn.start())
        #expect(await sleeps.durations == [.seconds(10), .seconds(15)])
    }

    @Test(arguments: failures) func endedSignInThrows(answer: String, failure: GitHubSignIn.Failure) async throws {
        let exchange = GitHubExchange(Self.deviceCode, answer)
        let signIn = signIn(exchange)
        let code = try await signIn.start()
        await #expect(throws: failure) { try await signIn.token(for: code) }
    }

    @Test func unreadableCodeAnswerIsNotQuoted() async throws {
        let answer = #"{"device_code": "3584d83530557fdd1f46af8289938c8ef79f9dc5", "interval": 5}"#
        let error = await #expect(throws: GitHubError.self) { try await signIn(GitHubExchange(answer)).start() }
        guard case .notUnderstood(let text) = error else {
            Issue.record("expected notUnderstood, got \(String(describing: error))")
            return
        }
        #expect(!text.contains("3584d835"))
    }

    @Test func failedTokenRequestIsNotQuoted() async throws {
        let exchange = GitHubExchange([(200, Self.deviceCode), (400, #"{"access_token": "gho_madeup"}"#)])
        let signIn = signIn(exchange)
        let code = try await signIn.start()
        await #expect(throws: GitHubError.rejected(status: 400, body: "")) { try await signIn.token(for: code) }
    }

    @Test func ghTokenIsTrimmed() async throws {
        let gh = try FakeTool.script(named: "gh", #"[ "$1 $2" = "auth token" ] && printf 'tok\n'"#)
        #expect(try await GitHubSignIn.ghToken(gh: gh) == "tok")
    }

    @Test func ghThatHangsTimesOut() async throws {
        let gh = try FakeTool.script(named: "gh", "sleep 30")
        let start = ContinuousClock.now
        await #expect(throws: ToolError.timedOut) {
            try await GitHubSignIn.ghToken(gh: gh, timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - start < .seconds(4))
    }

    @Test func ghExitingOneThrows() async throws {
        let gh = try FakeTool.script(named: "gh", "echo 'You are not logged into any GitHub hosts.' >&2; exit 1")
        await #expect(throws: GitHubError.signedOut) { try await GitHubSignIn.ghToken(gh: gh) }
    }

    @Test func ghPrintingNothingThrows() async throws {
        let gh = try FakeTool.script(named: "gh", "exit 0")
        await #expect(throws: GitHubError.signedOut) { try await GitHubSignIn.ghToken(gh: gh) }
    }
}
