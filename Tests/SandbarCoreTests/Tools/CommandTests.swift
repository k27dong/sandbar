import Foundation
import SandbarCore
import Testing

struct CommandTests {
    static let sh = URL(filePath: "/bin/sh")

    @Test func runCollectsBothStreamsAndTheStatus() async throws {
        let output = try await Command.run(Self.sh, ["-c", "printf hello; printf oops >&2; exit 3"])
        #expect(output.status == 3)
        #expect(String(decoding: output.standardOutput, as: UTF8.self) == "hello")
        #expect(String(decoding: output.standardError, as: UTF8.self) == "oops")
    }

    @Test func runAddsToTheEnvironment() async throws {
        let output = try await Command.run(
            Self.sh, ["-c", "printf $SANDBAR_PROBE"], environment: ["SANDBAR_PROBE": "42"])
        #expect(String(decoding: output.standardOutput, as: UTF8.self) == "42")
    }

    @Test func runDoesNotBlockOnLargeOutput() async throws {
        let output = try await Command.run(Self.sh, ["-c", "head -c 1048576 /dev/zero"])
        #expect(output.standardOutput.count == 1_048_576)
    }

    @Test func aMissingProgramIsMissing() async {
        await #expect(throws: ToolError.missing) {
            try await Command.run(URL(filePath: "/nonexistent/tool"))
        }
    }

    @Test func aHangingProgramTimesOut() async {
        let start = ContinuousClock.now
        await #expect(throws: ToolError.timedOut) {
            try await Command.run(Self.sh, ["-c", "sleep 30"], timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func aRunningProgramAnswersLineByLine() async throws {
        let running = try Command.start(Self.sh, ["-c", "while read l; do echo got $l; done"])
        try running.send("ping")
        var lines = running.lines.makeAsyncIterator()
        #expect(await lines.next() == "got ping")
        running.stop()
        #expect(await lines.next() == nil)
    }
}
