import Foundation

package enum ToolLocation {
    package static var loginShell: URL {
        guard let account = getpwuid(getuid()), let shell = account.pointee.pw_shell else {
            return URL(filePath: "/bin/zsh")
        }
        return URL(filePath: String(cString: shell))
    }

    package static var usualFolders: [URL] {
        [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin"),
            URL(filePath: "/opt/homebrew/bin"),
            URL(filePath: "/usr/local/bin"),
        ]
    }

    package static func searchPath(shell: URL = loginShell) async throws -> String {
        let asked = try await Command.run(shell, ["-lc", "printf '%s\\n' \"$PATH\""], timeout: .seconds(5))
        let printed = String(decoding: asked.standardOutput, as: UTF8.self)
        guard asked.status == 0 else {
            throw ToolError.failed(
                status: asked.status, output: String(decoding: asked.standardError.prefix(2_000), as: UTF8.self))
        }
        guard let path = printed.split(separator: "\n").last(where: { $0.hasPrefix("/") }) else {
            throw ToolError.notUnderstood(String(printed.suffix(2_000)))  // a login file may print before the path
        }
        return String(path)
    }

    package static func find(_ name: String, shell: URL = loginShell, folders: [URL] = usualFolders) async -> URL? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-".utf8)
        guard !name.isEmpty, name.utf8.allSatisfy(allowed.contains) else { return nil }
        let asked = try? await Command.run(  // a shell that fails or hangs leaves the usual folders to try
            shell, ["-lc", "command -v \(name)"], timeout: .seconds(5))
        if let asked {
            let printed = String(decoding: asked.standardOutput, as: UTF8.self).split(separator: "\n")
            if let path = printed.last(where: {
                $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: String($0))
            }) {
                return URL(filePath: String(path))
            }
        }
        return folders.map { $0.appending(path: name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
