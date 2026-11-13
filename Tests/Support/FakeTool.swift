import Foundation

package enum FakeTool {
    package static func script(named name: String, _ body: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sandbar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appending(path: name)
        let descriptor = open(script.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o755)  // no launch may inherit it
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let written = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try written.write(contentsOf: Data("#!/bin/sh\n\(body)\n".utf8))
        try written.close()
        return script
    }

    package static func codexServer(answering answers: String) throws -> URL {
        try script(
            named: "codex-app-server",
            """
            while read -r line; do
              id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
              case "$line" in
                *'"method":"initialize"'*) echo "{\\"id\\":$id,\\"result\\":{\\"userAgent\\":\\"fake\\"}}" ;;
                \(answers)
              esac
            done
            """
        )
    }
}
