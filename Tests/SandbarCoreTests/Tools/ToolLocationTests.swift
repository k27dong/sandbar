import Foundation
import SandbarCore
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

    @Test func aNameWithOtherCharactersRunsNothing() async throws {
        let shell = try FakeTool.script(named: "zsh", "touch \"$(dirname \"$0\")/ran\"")
        let marker = shell.deletingLastPathComponent().appending(path: "ran")
        #expect(await ToolLocation.find("gh; rm -rf x", shell: shell, folders: []) == nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        _ = await ToolLocation.find("gh", shell: shell, folders: [])
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }
}
