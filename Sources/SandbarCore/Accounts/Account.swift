import Foundation

package struct Account: Codable, Hashable, Identifiable, Sendable {
    package enum Unreadable: Error { case file(URL) }
    package enum Misplaced: Error, Equatable { case profile(URL) }

    package var id: UUID
    package var tool: Tool
    package var name: String
    package var plan: String
    package var profile: URL?

    package init(id: UUID = UUID(), tool: Tool, name: String, plan: String, profile: URL?) {
        self.id = id
        self.tool = tool
        self.name = name
        self.plan = plan
        self.profile = profile
    }

    package var title: String { plan.isEmpty ? name : "\(name) (\(plan))" }

    package var environment: [String: String] {
        switch tool {
        case .claude:
            var environment = ["DISABLE_AUTOUPDATER": "1"]  // Sandbar never makes the user's tool update itself
            if let profile { environment["CLAUDE_CONFIG_DIR"] = profile.path }
            return environment
        case .codex:
            guard let profile else { return [:] }
            return ["CODEX_HOME": profile.path]
        }
    }

    package static func load(from file: URL) throws -> [Account] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        do {
            return try JSONDecoder().decode([Account].self, from: try Data(contentsOf: file))
        } catch is DecodingError {
            throw Unreadable.file(file)
        }
    }

    package static func save(_ accounts: [Account], to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(accounts).write(to: file, options: .atomic)
    }

    package static func makeProfile(in profiles: URL) throws -> URL {
        let profile = profiles.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return profile
    }

    package func profileToForget(in profiles: URL) throws -> URL? {
        guard let profile else { return nil }  // the user's own sign-in is theirs to keep
        var entry = stat()
        guard lstat(profile.path, &entry) == 0 else {
            if errno == ENOENT { return nil }  // already gone: nothing to sign out of, nothing to delete
            throw Misplaced.profile(profile)
        }
        guard
            entry.st_mode & S_IFMT == S_IFDIR,  // a symlink is refused, never followed
            let folder = Self.realPath(of: profile), let realProfiles = Self.realPath(of: profiles),
            URL(filePath: folder).deletingLastPathComponent().path == realProfiles
        else { throw Misplaced.profile(profile) }
        return URL(filePath: folder, directoryHint: .isDirectory)
    }

    package func forget(tool program: URL?, profiles: URL) async throws {
        guard let folder = try profileToForget(in: profiles) else { return }
        if let program {  // with no tool anywhere there is nothing to sign out through, and the account must still go
            var checked = self
            checked.profile = folder  // what was checked is what is touched
            switch tool {
            case .claude: try await ClaudeSignIn.signOut(tool: program, environment: checked.environment)
            case .codex: try await CodexSignIn.signOut(tool: program, environment: checked.environment)
            }
        }
        try FileManager.default.removeItem(at: folder)
    }

    private static func realPath(of url: URL) -> String? {
        guard let real = realpath(url.path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }
}

package struct AccountStatus: Equatable, Sendable {
    package var isSignedIn: Bool
    package var organization: String?
    package var plan: String?

    package init(isSignedIn: Bool, organization: String?, plan: String?) {
        self.isSignedIn = isSignedIn
        self.organization = organization
        self.plan = plan
    }

    init(isSignedIn: Bool, organization: String?, planWord: String?) {
        self.init(
            isSignedIn: isSignedIn, organization: organization,
            plan: planWord.map { $0.prefix(1).uppercased() + $0.dropFirst() })
    }
}
