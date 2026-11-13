import Foundation
import SandbarCore
import Testing

@Suite(.enabled(if: Live.isOn), .serialized)
struct AccountsLiveTests {
    func emptyProfile(for tool: Tool) throws -> Account {
        let profiles = FileManager.default.temporaryDirectory.appending(path: "sandbar-\(UUID().uuidString)")
        return Account(tool: tool, name: "Work", plan: "Enterprise", profile: try Account.makeProfile(in: profiles))
    }

    @Test func bothToolsAreSignedInWithAPlan() async throws {
        let claude = try await ClaudeSignIn.status(
            tool: Live.program("SANDBAR_LIVE_CLAUDE"),
            environment: Account(tool: .claude, name: "Work", plan: "", profile: nil).environment)
        let codex = try await CodexSignIn.status(
            tool: Live.program("SANDBAR_LIVE_CODEX"),
            environment: Account(tool: .codex, name: "Work", plan: "", profile: nil).environment)
        let claudeHasPlan = claude.isSignedIn && !(claude.plan ?? "").isEmpty  // never print the real organization
        let codexHasPlan = codex.isSignedIn && !(codex.plan ?? "").isEmpty
        #expect(claudeHasPlan)
        #expect(codexHasPlan)
    }

    @Test func bothToolsAreSignedOutInAnEmptyProfile() async throws {
        let claude = try emptyProfile(for: .claude)
        let codex = try emptyProfile(for: .codex)
        let claudeStatus = try await ClaudeSignIn.status(
            tool: Live.program("SANDBAR_LIVE_CLAUDE"), environment: claude.environment)
        let codexStatus = try await CodexSignIn.status(
            tool: Live.program("SANDBAR_LIVE_CODEX"), environment: codex.environment)
        #expect(claudeStatus == AccountStatus(isSignedIn: false, organization: nil, plan: nil))
        #expect(codexStatus == AccountStatus(isSignedIn: false, organization: nil, plan: nil))
    }

    @Test func aCodexSignInStartsAndIsCancelled() async throws {
        let codex = try emptyProfile(for: .codex)
        let pending = try await CodexSignIn.begin(
            tool: Live.program("SANDBAR_LIVE_CODEX"), environment: codex.environment)
        #expect(pending.address.scheme == "https")
        await pending.cancel()
    }

    @Test func aClaudeSignInStartsAndIsStopped() async throws {
        let claude = try emptyProfile(for: .claude)
        let running = try await ClaudeSignIn.begin(
            tool: Live.program("SANDBAR_LIVE_CLAUDE"), environment: claude.environment)
        let deadline = Task {
            try await Task.sleep(for: .seconds(30))
            running.stop()
        }
        var address: URL?
        for await line in running.lines {
            address = ClaudeSignIn.address(in: line)
            if address != nil { break }
        }
        deadline.cancel()
        running.stop()
        #expect(address?.scheme == "https")
    }
}
