import Foundation
import SandbarCore
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct ToolDownloadTests {
    static let releases = "https://downloads.claude.ai/claude-code-releases"
    static let codexRelease = "https://api.github.com/repos/openai/codex/releases/latest"
    static let codexAssets = "https://github.com/openai/codex/releases/download/rust-v0.167.2"
    static let manifest = """
        {"version": "2.1.400", "platforms": {
          "darwin-arm64": {"checksum": "aa11", "size": 6},
          "linux-x64": {"checksum": "ff00", "size": 6}}}
        """
    static let release = """
        {"tag_name": "rust-v0.167.2", "assets": [
          {"name": "codex-app-server-x86_64-apple-darwin.tar.gz",
           "browser_download_url": "\(codexAssets)/codex-app-server-x86_64-apple-darwin.tar.gz",
           "digest": "sha256:ff00"},
          {"name": "codex-app-server-aarch64-apple-darwin.tar.gz",
           "browser_download_url": "\(codexAssets)/codex-app-server-aarch64-apple-darwin.tar.gz",
           "digest": "sha256:cc33"}]}
        """
    static let wrongChecksumCases: [(tool: Tool, expected: String)] = [(.claude, "aa11"), (.codex, "cc33")]

    actor Downloads {
        var addresses: [URL] = []
        func add(_ address: URL) { addresses.append(address) }
    }

    let folder = FileManager.default.temporaryDirectory.appending(path: "sandbar-\(UUID().uuidString)")
    let downloads = Downloads()

    func stub(latest: String = "2.1.400\n", checksum: String = "aa11", archive: URL? = nil) -> ToolDownload {
        let answers = [
            "\(Self.releases)/latest": latest,
            "\(Self.releases)/\(latest.trimmingCharacters(in: .whitespacesAndNewlines))/manifest.json":
                Self.manifest.replacingOccurrences(of: "2.1.400", with: latest),
            Self.codexRelease: Self.release,
        ]
        let downloads = downloads
        return ToolDownload(
            folder: folder,
            fetch: { address in
                guard let answer = answers[address.absoluteString] else { throw URLError(.fileDoesNotExist) }
                return Data(answer.utf8)
            },
            download: { from, to in
                await downloads.add(from)
                if let archive {
                    try FileManager.default.copyItem(at: archive, to: to)
                } else {
                    try Data("binary".utf8).write(to: to)
                }
            },
            sha256: { _ in checksum }
        )
    }

    func codexArchive(triple: String) async throws -> URL {
        let program = try FakeTool.script(named: "codex-app-server-\(triple)", "exit 0")
        let archive = program.deletingLastPathComponent().appending(path: "codex.tar.gz")
        let packed = try await Command.run(
            URL(filePath: "/usr/bin/tar"),
            ["-czf", archive.path, "-C", program.deletingLastPathComponent().path, program.lastPathComponent]
        )
        try #require(packed.status == 0)
        return archive
    }

    @Test func claudeLandsInItsVersionFolder() async throws {
        let program = try await stub().install(.claude, platform: .macArm)
        #expect(program == folder.appending(path: "claude/2.1.400/claude"))
        let mode = try FileManager.default.attributesOfItem(atPath: program.path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        #expect(await downloads.addresses == [URL(string: "\(Self.releases)/2.1.400/darwin-arm64/claude")!])
    }

    @Test(arguments: wrongChecksumCases) func aWrongChecksumLeavesNothing(tool: Tool, expected: String) async throws {
        let download = stub(checksum: "bb22", archive: try await codexArchive(triple: "aarch64-apple-darwin"))
        await #expect(throws: DownloadError.checksum(expected: expected, got: "bb22")) {
            try await download.install(tool, platform: .macArm)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func aLatestThatIsNotAVersionIsNotUnderstood() async {
        await #expect(throws: ToolError.notUnderstood("<html>")) {
            try await stub(latest: "<html>").install(.claude, platform: .macArm)
        }
    }

    @Test func aNewVersionReplacesTheOldOne() async throws {
        _ = try await stub(latest: "2.1.99").install(.claude, platform: .macArm)
        let program = try await stub(latest: "2.1.400").install(.claude, platform: .macArm)
        #expect(program == folder.appending(path: "claude/2.1.400/claude"))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "claude/2.1.99").path))
    }

    @Test func theHighestVersionNumberIsTheInstalledOne() async throws {
        for version in ["2.1.99", "2.1.400"] {
            let program = folder.appending(path: "claude/\(version)/claude")
            try FileManager.default.createDirectory(
                at: program.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("binary".utf8).write(to: program)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        }
        #expect(stub().installed(.claude) == folder.appending(path: "claude/2.1.400/claude"))
    }

    @Test func anInstalledLatestIsNotDownloadedAgain() async throws {
        let first = try await stub().install(.claude, platform: .macArm)
        let second = try await stub().install(.claude, platform: .macArm)
        #expect(first == second)
        #expect(await downloads.addresses.count == 1)
    }

    @Test func codexTakesTheAssetForTheMachine() async throws {
        let archive = try await codexArchive(triple: "aarch64-apple-darwin")
        let program = try await stub(checksum: "cc33", archive: archive).install(.codex, platform: .macArm)
        #expect(program == folder.appending(path: "codex/0.167.2/codex-app-server"))
        #expect(FileManager.default.isExecutableFile(atPath: program.path))
        let asset = "\(Self.codexAssets)/codex-app-server-aarch64-apple-darwin.tar.gz"
        #expect(await downloads.addresses == [URL(string: asset)!])
    }

    @Test func aReleaseWithoutTheMachinesAssetHasNoBuild() async {
        await #expect(throws: DownloadError.noBuild("aarch64-unknown-linux-musl")) {
            try await stub().install(.codex, platform: .linuxArm)
        }
    }
}

struct ToolDownloadLiveTests {
    struct AccountAnswer: Decodable, Sendable {
        struct Account: Decodable, Sendable {
            var type: String
        }
        var account: Account?
    }

    struct AccountRead: Encodable, Sendable {
        var refreshToken = false
    }

    @Test(.enabled(if: Live.isOn)) func codexFromTheRealReleaseAnswersSignedOut() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sandbar-\(UUID().uuidString)")
        let download = ToolDownload(
            folder: folder,
            fetch: { address in try await URLSession.shared.data(from: address).0 },
            download: { from, to in
                let (file, _) = try await URLSession.shared.download(from: from)
                try FileManager.default.moveItem(at: file, to: to)
            },
            sha256: { file in
                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/sha256sum")
                process.arguments = [file.path]
                let output = Pipe()
                process.standardOutput = output
                try process.run()
                let printed = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return String(String(decoding: printed, as: UTF8.self).prefix { $0 != " " })
            }
        )
        let program = try await download.install(.codex)
        let home = folder.appending(path: "codex-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let server = try await CodexServer(tool: program, environment: ["CODEX_HOME": home.path])
        let answer: AccountAnswer = try await server.ask("account/read", AccountRead())
        await server.stop()
        #expect(answer.account == nil)
    }
}
