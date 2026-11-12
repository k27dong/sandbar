import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if canImport(CryptoKit)
    import CryptoKit
#endif

package enum Tool: String, Codable, CaseIterable, Sendable {
    case claude, codex

    package var programName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

package enum DownloadError: Error, Equatable {
    case checksum(expected: String, got: String)
    case noBuild(String)
    case undated(URL)
    case failed(String)
}

package struct ToolDownload: Sendable {
    package enum Platform: Sendable {
        case macArm, macIntel, linuxArm, linuxIntel

        package static var current: Platform {
            #if os(macOS) && arch(arm64)
                .macArm
            #elseif os(macOS)
                .macIntel
            #elseif arch(arm64)
                .linuxArm
            #else
                .linuxIntel
            #endif
        }
    }

    package var folder: URL
    package var fetch: @Sendable (URL) async throws -> Data
    package var download: @Sendable (_ from: URL, _ to: URL) async throws -> Void
    package var sha256: @Sendable (URL) throws -> String

    private static let claudeReleases = URL(string: "https://downloads.claude.ai/claude-code-releases")!
    private static let codexRelease = URL(string: "https://api.github.com/repos/openai/codex/releases/latest")!
    private static let codexProgram = "codex-app-server"
    private static let copyLifetime: TimeInterval = 14 * 86_400

    package init(
        folder: URL,
        fetch: @escaping @Sendable (URL) async throws -> Data,
        download: @escaping @Sendable (_ from: URL, _ to: URL) async throws -> Void,
        sha256: @escaping @Sendable (URL) throws -> String
    ) {
        self.folder = folder
        self.fetch = fetch
        self.download = download
        self.sha256 = sha256
    }

    #if canImport(CryptoKit)
        package init(folder: URL) {
            self.init(
                folder: folder,
                fetch: { address in
                    let (data, response) = try await URLSession.shared.data(from: address)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    return data
                },
                download: { from, to in
                    let (file, response) = try await URLSession.shared.download(from: from)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    try FileManager.default.moveItem(at: file, to: to)
                },
                sha256: { file in
                    SHA256.hash(data: try Data(contentsOf: file, options: .alwaysMapped))
                        .map { String(format: "%02x", $0) }.joined()
                }
            )
        }
    #endif

    package func installed(_ tool: Tool) throws -> URL? {
        let toolFolder = folder.appending(path: tool.rawValue)
        guard FileManager.default.fileExists(atPath: toolFolder.path) else { return nil }
        return try FileManager.default.contentsOfDirectory(atPath: toolFolder.path).filter(Self.isVersion)
            .sorted { Self.numbers(of: $0).lexicographicallyPrecedes(Self.numbers(of: $1)) }
            .reversed()
            .map { place(tool, $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    package func isOld(_ tool: Tool, at now: Date) throws -> Bool {
        guard let program = try installed(tool) else { return false }
        let attributes = try FileManager.default.attributesOfItem(atPath: program.path)
        guard let installedAt = attributes[.modificationDate] as? Date else { throw DownloadError.undated(program) }
        return now.timeIntervalSince(installedAt) >= Self.copyLifetime
    }

    package func install(_ tool: Tool, platform: Platform = .current) async throws -> URL {
        switch tool {
        case .claude: try await installClaude(platform)
        case .codex: try await installCodex(platform)
        }
    }

    private func installClaude(_ platform: Platform) async throws -> URL {
        let latest = String(decoding: try await fetch(Self.claudeReleases.appending(path: "latest")), as: UTF8.self)
        let version = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isVersion(version) else { throw ToolError.notUnderstood(String(latest.prefix(2_000))) }
        let program = place(.claude, version)
        if FileManager.default.fileExists(atPath: program.path) { return program }

        struct Manifest: Decodable {
            struct Build: Decodable { var checksum: String }
            var platforms: [String: Build]
        }
        let release = Self.claudeReleases.appending(path: version)
        let manifest: Manifest = try Self.decode(try await fetch(release.appending(path: "manifest.json")))
        let name =
            switch platform {
            case .macArm: "darwin-arm64"
            case .macIntel: "darwin-x64"
            case .linuxArm: "linux-arm64"
            case .linuxIntel: "linux-x64"
            }
        guard let build = manifest.platforms[name] else { throw DownloadError.noBuild(name) }
        try await keep(.claude, version, from: release.appending(path: "\(name)/claude"), checksum: build.checksum)
        return program
    }

    private func installCodex(_ platform: Platform) async throws -> URL {
        struct Release: Decodable {
            struct Asset: Decodable {
                var name: String
                var address: URL
                var digest: String

                enum CodingKeys: String, CodingKey {
                    case name, digest
                    case address = "browser_download_url"
                }
            }
            var tag: String
            var assets: [Asset]

            enum CodingKeys: String, CodingKey {
                case assets
                case tag = "tag_name"
            }
        }
        let release: Release = try Self.decode(try await fetch(Self.codexRelease))
        let version = String(release.tag.trimmingPrefix("rust-v"))
        guard release.tag.hasPrefix("rust-v"), Self.isVersion(version) else {
            throw ToolError.notUnderstood(release.tag)
        }
        let program = place(.codex, version)
        if FileManager.default.fileExists(atPath: program.path) { return program }

        let triple =
            switch platform {
            case .macArm: "aarch64-apple-darwin"
            case .macIntel: "x86_64-apple-darwin"
            case .linuxArm: "aarch64-unknown-linux-musl"
            case .linuxIntel: "x86_64-unknown-linux-musl"
            }
        let member = "\(Self.codexProgram)-\(triple)"
        guard let asset = release.assets.first(where: { $0.name == "\(member).tar.gz" }) else {
            throw DownloadError.noBuild(triple)
        }
        guard asset.digest.hasPrefix("sha256:") else { throw ToolError.notUnderstood(asset.digest) }
        try await keep(
            .codex, version, from: asset.address, checksum: String(asset.digest.dropFirst(7)), unpacking: member)
        return program
    }

    private func keep(
        _ tool: Tool, _ version: String, from address: URL, checksum: String, unpacking member: String? = nil
    ) async throws {
        let scratch = folder.appending(path: ".download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }  // a leftover costs disk space, never the result
        let downloaded = scratch.appending(path: "download")
        try await download(address, downloaded)
        let got = try sha256(downloaded)
        guard got.lowercased() == checksum.lowercased() else {
            throw DownloadError.checksum(expected: checksum, got: got)
        }
        var file = downloaded
        if let member {
            let tar = try await Command.run(
                URL(filePath: "/usr/bin/tar"), ["-xzf", downloaded.path, "-C", scratch.path])
            guard tar.status == 0 else {
                throw ToolError.failed(status: tar.status, output: String(decoding: tar.standardError, as: UTF8.self))
            }
            file = scratch.appending(path: member)
        }
        let program = place(tool, version)
        try FileManager.default.createDirectory(
            at: program.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: program)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755, .modificationDate: Date.now],  // a copy ages from the fetch, not from its build
            ofItemAtPath: program.path)
        let toolFolder = folder.appending(path: tool.rawValue)
        for entry in try FileManager.default.contentsOfDirectory(atPath: toolFolder.path) where entry != version {
            try FileManager.default.removeItem(at: toolFolder.appending(path: entry))
        }
    }

    private func place(_ tool: Tool, _ version: String) -> URL {
        let program =
            switch tool {
            case .claude: "claude"
            case .codex: Self.codexProgram
            }
        return folder.appending(path: "\(tool.rawValue)/\(version)/\(program)")
    }

    private static func isVersion(_ text: String) -> Bool {
        text.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?/.matchingSemantics(.unicodeScalar)) != nil
    }

    private static func numbers(of version: String) -> [Int] {
        version.prefix { $0 != "-" }.split(separator: ".").compactMap { Int($0) }
    }

    private static func decode<Answer: Decodable>(_ data: Data) throws -> Answer {
        do {
            return try JSONDecoder().decode(Answer.self, from: data)
        } catch is DecodingError {
            throw ToolError.notUnderstood(String(decoding: data.prefix(2_000), as: UTF8.self))
        }
    }
}
