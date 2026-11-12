import Foundation
import SandbarCore
import Testing

struct FetchedToolsTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SANDBAR_FETCH"] == "1"))
    func sandbarsOwnCopiesRunFromItsFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sandbar-\(UUID().uuidString)")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let download = ToolDownload(folder: folder.appending(path: "Tools"))
        let profiles = folder.appending(path: "Profiles")

        let claude = try await download.install(.claude)
        let work = Account(tool: .claude, name: "Work", plan: "", profile: try Account.makeProfile(in: profiles))
        let version = try await Command.run(claude, ["--version"], environment: work.environment, timeout: .seconds(60))
        #expect(version.status == 0)
        #expect(String(decoding: version.standardOutput, as: UTF8.self).contains(/[0-9]+\.[0-9]+\.[0-9]+/))

        let codex = try await download.install(.codex)
        let personal = Account(tool: .codex, name: "Personal", plan: "", profile: try Account.makeProfile(in: profiles))
        let status = try await CodexSignIn.status(tool: codex, environment: personal.environment)
        #expect(status == AccountStatus(isSignedIn: false, organization: nil, plan: nil))
    }
}
