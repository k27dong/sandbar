import Foundation
import SandbarCore
import SandbarTestSupport
import Testing

struct ToolLocationTests {
    static let sh = URL(filePath: "/bin/sh")

    @Test func theLoginShellIsAskedFirstAndItsLastPathCounts() async throws {
        let claude = try FakeTool.script(named: "claude", "exit 0")
        let shell = try FakeTool.script(named: "zsh", "echo Welcome\necho \(claude.path)")
        #expect(await ToolLocation.find("claude", shell: shell, folders: []) == claude)
    }

    @Test func aToolInAListedFolderIsFound() async throws {
        let tool = try FakeTool.script(named: "sandbar-only-here", "exit 0")
        let found = await ToolLocation.find(
            "sandbar-only-here", shell: Self.sh, folders: [tool.deletingLastPathComponent()])
        #expect(found == tool)
    }

    @Test func anUnknownToolIsNil() async throws {
        let empty = try FakeTool.script(named: "unrelated", "exit 0").deletingLastPathComponent()
        #expect(await ToolLocation.find("sandbar-unknown", shell: Self.sh, folders: [empty]) == nil)
    }

    @Test func theLoginShellsSearchPathIsItsLastPathLine() async throws {
        let shell = try FakeTool.script(named: "zsh", "echo Welcome\necho /opt/tools/bin:/usr/bin:/bin")
        #expect(try await ToolLocation.searchPath(shell: shell) == "/opt/tools/bin:/usr/bin:/bin")
    }

    @Test func aShellThatFailsGivesNoSearchPath() async throws {
        let shell = try FakeTool.script(named: "zsh", "echo /usr/bin\nexit 3")
        await #expect(throws: ToolError.failed(status: 3, output: "")) {
            try await ToolLocation.searchPath(shell: shell)
        }
    }

    @Test func aShellThatPrintsNoPathGivesNoSearchPath() async throws {
        let shell = try FakeTool.script(named: "zsh", "echo Welcome")
        await #expect(throws: ToolError.notUnderstood("Welcome\n")) {
            try await ToolLocation.searchPath(shell: shell)
        }
    }

    @Test func aNameWithOtherCharactersRunsNothing() async throws {
        let shell = try FakeTool.script(named: "zsh", "touch \"$(dirname \"$0\")/ran\"")
        let marker = shell.deletingLastPathComponent().appending(path: "ran")
        #expect(await ToolLocation.find("gh; rm -rf x", shell: shell, folders: []) == nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        _ = await ToolLocation.find("gh", shell: shell, folders: [])
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }
}
