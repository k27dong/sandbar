import Foundation
import SandbarCore
import Testing

struct ClaudeSignInTests {
    func claude(answeringStatus answer: String) throws -> URL {
        try FakeTool.script(named: "claude", #"[ "$*" = "auth status" ] || exit 2"# + "\n" + answer)
    }

    @Test func aSignedInAccountGivesItsOrganizationAndPlan() async throws {
        let tool = try claude(
            answeringStatus: #"echo '{"loggedIn": true, "orgName": "Acme Robotics", "subscriptionType": "enterprise"}'"#
        )
        let status = try await ClaudeSignIn.status(tool: tool, environment: [:])
        #expect(status == AccountStatus(isSignedIn: true, organization: "Acme Robotics", plan: "Enterprise"))
    }

    @Test func aSignedOutAccountIsSignedOutWhateverTheExitStatus() async throws {
        let tool = try claude(answeringStatus: #"echo '{"loggedIn": false}'; exit 1"#)
        let status = try await ClaudeSignIn.status(tool: tool, environment: [:])
        #expect(status == AccountStatus(isSignedIn: false, organization: nil, plan: nil))
    }

    @Test func anAnswerThatIsNotStatusIsNotUnderstood() async throws {
        let tool = try claude(answeringStatus: "printf hello")
        await #expect(throws: ToolError.notUnderstood("hello")) {
            try await ClaudeSignIn.status(tool: tool, environment: [:])
        }
    }

    @Test func signingInShowsTheAddressAndTakesTheCode() async throws {
        let tool = try FakeTool.script(
            named: "claude",
            """
            [ "$*" = "auth login" ] || exit 2
            echo "https://claude.example/oauth/authorize?code=true"
            read -r code
            [ "$code" = "code-123" ]
            """
        )
        let running = try ClaudeSignIn.begin(tool: tool, environment: [:])
        var lines = running.lines.makeAsyncIterator()
        #expect(await lines.next() == "https://claude.example/oauth/authorize?code=true")
        try running.send("code-123")
        #expect(await running.status() == 0)
    }

    @Test func theAddressIsFoundInItsLine() {
        let line = "If the browser didn't open, visit: https://claude.example/oauth/authorize?code=true&state=abc"
        #expect(
            ClaudeSignIn.address(in: line) == URL(string: "https://claude.example/oauth/authorize?code=true&state=abc"))
    }

    @Test func aLineWithoutAnAddressHasNone() {
        #expect(ClaudeSignIn.address(in: "Opening browser to sign in…") == nil)
    }
}
