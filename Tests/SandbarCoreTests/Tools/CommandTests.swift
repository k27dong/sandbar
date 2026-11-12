import Foundation
import SandbarCore
import Testing

struct CommandTests {
    static let sh = URL(filePath: "/bin/sh")
    static let startFailureCases: [(failure: Int32, retried: Bool)] = [
        (ETXTBSY, true), (ENOENT, false), (EACCES, false), (ENOEXEC, false),
    ]
    static let stubbornCases = ["trap '' TERM; sleep 6", "setsid sleep 6 & sleep 30"]

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

    @Test(arguments: startFailureCases) func onlyABusyProgramIsRetried(failure: Int32, retried: Bool) {
        let started = NSError(
            domain: NSCocoaErrorDomain, code: CocoaError.fileReadUnknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(failure))])
        #expect(Command.isWorthRetrying(started) == retried)
    }

    @Test func aProgramStillBeingWrittenStartsOnceItIsDone() async throws {
        let program = try FakeTool.script(named: "busy", "printf ok")
        let descriptor = open(program.path, O_WRONLY | O_CLOEXEC)
        try #require(descriptor >= 0)
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.05)
            close(descriptor)
        }
        let output = try await Command.run(program)
        #expect(String(decoding: output.standardOutput, as: UTF8.self) == "ok")
    }

    @Test func aHangingProgramTimesOut() async {
        let start = ContinuousClock.now
        await #expect(throws: ToolError.timedOut) {
            try await Command.run(Self.sh, ["-c", "sleep 30"], timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - start < .seconds(4))
    }

    @Test(arguments: stubbornCases) func aStubbornProgramStillTimesOut(script: String) async {
        let start = ContinuousClock.now
        await #expect(throws: ToolError.timedOut) {
            try await Command.run(Self.sh, ["-c", script], timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - start < .seconds(4))
    }

    @Test func cancellingEndsTheRun() async {
        let start = ContinuousClock.now
        let running = Task { try await Command.run(Self.sh, ["-c", "trap '' TERM; sleep 30"]) }
        try? await Task.sleep(for: .milliseconds(300))
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(ContinuousClock.now - start < .seconds(4))
    }

    @Test func aRunningProgramAnswersLineByLine() async throws {
        let running = try Command.start(Self.sh, ["-c", "while read l; do echo got $l; done"])
        try running.send("ping")
        var lines = running.lines.makeAsyncIterator()
        #expect(await lines.next() == "got ping")
        running.stop()
        #expect(await lines.next() == nil)
    }

    @Test func aSendToAnEndedProgramThrows() async throws {
        let running = try Command.start(Self.sh, ["-c", "exit 0"])
        _ = await running.status()
        #expect(throws: (any Error).self) { try running.send("ping") }
    }

    @Test func aReleasedRunningEndsItsProgram() async throws {
        let start = ContinuousClock.now
        var lines: AsyncStream<String>.Iterator
        do {
            let running = try Command.start(Self.sh, ["-c", "sleep 30"])
            lines = running.lines.makeAsyncIterator()
        }
        #expect(await lines.next() == nil)
        #expect(ContinuousClock.now - start < .seconds(4))
    }
}
