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

    func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sandbar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
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

    @Test func aProfileOutsideProfilesIsNeverForgotten() async throws {
        let profiles = try folder()
        let outside = try Account.makeProfile(in: try folder())
        let tool = try signOutRecorder()
        await #expect(throws: Account.Misplaced.profile(outside)) {
            try await Account(tool: .claude, name: "Work", plan: "Enterprise", profile: outside)
                .forget(tool: tool, profiles: profiles)
        }
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(try called(tool) == nil)
    }
}
