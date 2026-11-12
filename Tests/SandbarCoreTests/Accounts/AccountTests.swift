import Foundation
import SandbarCore
import Testing

struct AccountTests {
    static let profile = URL(filePath: "/Profiles/work")
    static let environmentCases: [(account: Account, environment: [String: String])] = [
        (Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil), ["DISABLE_AUTOUPDATER": "1"]),
        (
            Account(tool: .claude, name: "Work", plan: "Enterprise", profile: profile),
            ["DISABLE_AUTOUPDATER": "1", "CLAUDE_CONFIG_DIR": "/Profiles/work"]
        ),
        (Account(tool: .codex, name: "Personal", plan: "Team", profile: nil), [:]),
        (Account(tool: .codex, name: "Personal", plan: "Team", profile: profile), ["CODEX_HOME": "/Profiles/work"]),
    ]

    enum Misplacement: CaseIterable, Sendable {
        case sibling, symlink, symlinkThenParent, climbingOut, profilesItself, empty
    }

    func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sandbar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let real = try #require(realpath(folder.path, nil))  // macOS's temporary folder is behind a symlink
        defer { free(real) }
        return URL(filePath: String(cString: real), directoryHint: .isDirectory)
    }

    func profile(_ misplacement: Misplacement, profiles: URL, outside: URL) throws -> URL {
        let files = FileManager.default
        switch misplacement {
        case .sibling:
            return outside
        case .symlink:
            let link = profiles.appending(path: "link")
            try files.createSymbolicLink(at: link, withDestinationURL: outside)
            return link
        case .symlinkThenParent:
            try files.createDirectory(at: outside.appending(path: "inner"), withIntermediateDirectories: true)
            try files.createDirectory(at: outside.appending(path: "y"), withIntermediateDirectories: true)
            try files.createSymbolicLink(
                at: profiles.appending(path: "x"), withDestinationURL: outside.appending(path: "inner"))
            return URL(filePath: profiles.path + "/x/../y")
        case .climbingOut:
            return URL(filePath: profiles.path + "/../" + outside.lastPathComponent)
        case .profilesItself:
            return profiles
        case .empty:
            return URL(filePath: "")
        }
    }

    func signOutRecorder() throws -> URL {
        try FakeTool.script(
            named: "claude", #"echo "$* $CLAUDE_CONFIG_DIR" > "$(dirname "$0")/called""#)
    }

    func called(_ tool: URL) throws -> String? {
        let record = tool.deletingLastPathComponent().appending(path: "called")
        guard FileManager.default.fileExists(atPath: record.path) else { return nil }
        return try String(contentsOf: record, encoding: .utf8)
    }

    @Test func theTitleIsTheNameAndThePlan() {
        #expect(Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil).title == "Work (Enterprise)")
    }

    @Test(arguments: environmentCases) func theEnvironmentPointsTheToolAtItsProfile(
        account: Account, environment: [String: String]
    ) {
        #expect(account.environment == environment)
    }

    @Test func aMissingFileIsNoAccounts() throws {
        #expect(try Account.load(from: try folder().appending(path: "accounts.json")) == [])
    }

    @Test func savedAccountsLoadTheSame() throws {
        let file = try folder().appending(path: "accounts.json")
        let accounts = [
            Account(tool: .claude, name: "Work", plan: "Enterprise", profile: Self.profile),
            Account(tool: .codex, name: "Personal", plan: "Team", profile: nil),
        ]
        try Account.save(accounts, to: file)
        #expect(try Account.load(from: file) == accounts)
    }

    @Test func aFileThatIsNotAccountsIsUnreadable() throws {
        let file = try folder().appending(path: "accounts.json")
        try Data("not json".utf8).write(to: file)
        #expect(throws: Account.Unreadable.self) { try Account.load(from: file) }
    }

    @Test func aNewProfileIsAPrivateFolderInsideProfiles() throws {
        let profiles = try folder()
        let profile = try Account.makeProfile(in: profiles)
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: profile.path, isDirectory: &isFolder) && isFolder.boolValue)
        #expect(profile.deletingLastPathComponent().path == profiles.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: profile.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func forgettingSignsOutThroughTheToolAndRemovesTheProfile() async throws {
        let profiles = try folder()
        let profile = try Account.makeProfile(in: profiles)
        let tool = try signOutRecorder()
        try await Account(tool: .claude, name: "Work", plan: "Enterprise", profile: profile)
            .forget(tool: tool, profiles: profiles)
        #expect(try called(tool) == "auth logout \(profile.path)\n")
        #expect(!FileManager.default.fileExists(atPath: profile.path))
    }

    @Test func forgettingTheUsersOwnSignInRunsNothing() async throws {
        let tool = try signOutRecorder()
        try await Account(tool: .claude, name: "Work", plan: "Enterprise", profile: nil)
            .forget(tool: tool, profiles: try folder())
        #expect(try called(tool) == nil)
    }

    @Test func aProfileWrittenWithATrailingSlashIsForgotten() async throws {
        let profiles = try folder()
        let profile = try Account.makeProfile(in: profiles)
        let tool = try signOutRecorder()
        try await Account(tool: .claude, name: "Work", plan: "Enterprise", profile: URL(filePath: profile.path + "/"))
            .forget(tool: tool, profiles: profiles)
        #expect(try called(tool) == "auth logout \(profile.path)\n")
        #expect(!FileManager.default.fileExists(atPath: profile.path))
    }

    @Test func forgettingACodexAccountSignsOutThroughItsServer() async throws {
        let profiles = try folder()
        let profile = try Account.makeProfile(in: profiles)
        let tool = try FakeTool.script(
            named: "codex-app-server",
            """
            while read -r line; do
              id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
              case "$line" in
                *'"method":"initialize"'*) echo "{\\"id\\":$id,\\"result\\":{\\"userAgent\\":\\"fake\\"}}" ;;
                *'"method":"account/logout"'*)
                  echo "logout $CODEX_HOME" > "$(dirname "$0")/called"
                  echo "{\\"id\\":$id,\\"result\\":{}}" ;;
              esac
            done
            """
        )
        try await Account(tool: .codex, name: "Personal", plan: "Team", profile: profile)
            .forget(tool: tool, profiles: profiles)
        #expect(try called(tool) == "logout \(profile.path)\n")
        #expect(!FileManager.default.fileExists(atPath: profile.path))
    }

    @Test(arguments: Misplacement.allCases) func aProfileNotDirectlyInsideProfilesIsNeverForgotten(
        misplacement: Misplacement
    ) async throws {
        let root = try folder()
        let profiles = root.appending(path: "Profiles")
        let outside = root.appending(path: "outside")
        for kept in [profiles, outside] {
            try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
            try Data().write(to: kept.appending(path: "kept"))
        }
        let misplaced = try profile(misplacement, profiles: profiles, outside: outside)
        let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        let tool = try FakeTool.script(  // refusing to sign out keeps a broken check from reaching the delete
            named: "claude", #"echo "$*" > "$(dirname "$0")/called"; exit 1"#)
        await #expect(throws: Account.Misplaced.profile(misplaced)) {
            try await Account(tool: .claude, name: "Work", plan: "Enterprise", profile: misplaced)
                .forget(tool: tool, profiles: profiles)
        }
        #expect(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted() == before)
        #expect(try called(tool) == nil)
    }
}
