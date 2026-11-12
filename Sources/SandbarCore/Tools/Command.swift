import Foundation

package enum ToolError: Error, Equatable {
    case missing
    case signedOut
    case timedOut
    case failed(status: Int32, output: String)
    case notUnderstood(String)
}

package enum Command {
    package struct Output: Equatable, Sendable {
        package var status: Int32
        package var standardOutput: Data
        package var standardError: Data
    }

    package static func run(
        _ program: URL, _ arguments: [String] = [], environment: [String: String] = [:],
        timeout: Duration = .seconds(30)
    ) async throws -> Output {
        let output = try newPipe()
        let error = try newPipe()
        var started: Launched?
        for attempt in 1...10 where started == nil {
            do {
                started = try launch(
                    program, arguments, environment, input: FileHandle.nullDevice, output: output, error: error)
            } catch is FileBusy {
                guard attempt < 10 else { throw ToolError.missing }
                try await Task.sleep(for: .milliseconds(25))  // someone still holds the new file open
            }
        }
        guard let launched = started else { throw ToolError.missing }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Output?.self) { group in
                group.addTask {
                    async let standardOutput = collect(output.fileHandleForReading)
                    async let standardError = collect(error.fileHandleForReading)
                    let (printed, complained) = await (standardOutput, standardError)
                    try Task.checkCancellation()
                    return Output(status: await launched.exit.value, standardOutput: printed, standardError: complained)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                defer { group.cancelAll() }
                guard case let finished?? = try await group.next() else {
                    await launched.end()
                    throw ToolError.timedOut
                }
                return finished
            }
        } onCancel: {
            Task { await launched.end() }
        }
    }

    package static func start(
        _ program: URL, _ arguments: [String] = [], environment: [String: String] = [:]
    ) throws -> Running {
        let input = try newPipe()
        let output = try newPipe()
        #if canImport(Darwin)
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        #endif
        let launched: Launched
        do {
            launched = try launch(
                program, arguments, environment, input: input, output: output, error: FileHandle.nullDevice)
        } catch is FileBusy {
            throw ToolError.missing  // a synchronous start cannot wait without blocking a pool thread
        }
        return Running(launched: launched, input: input.fileHandleForWriting, output: output.fileHandleForReading)
    }

    package final class Running: Sendable {
        package let lines: AsyncStream<String>
        private let launched: Launched
        private let input: FileHandle

        fileprivate init(launched: Launched, input: FileHandle, output: FileHandle) {
            self.launched = launched
            self.input = input
            lines = AsyncStream { continuation in
                let reading = Task {
                    var pending: [UInt8] = []
                    for await chunk in chunks(of: output) {
                        pending.append(contentsOf: chunk)
                        while let end = pending.firstIndex(of: 0x0A) {
                            continuation.yield(String(decoding: pending[..<end], as: UTF8.self))
                            pending.removeSubrange(...end)
                        }
                    }
                    if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in reading.cancel() }
            }
        }

        deinit {
            stop()
        }

        package func send(_ line: String) throws {
            #if os(Linux)
                var brokenPipe = sigset_t()
                var blocked = sigset_t()
                sigemptyset(&brokenPipe)
                sigaddset(&brokenPipe, SIGPIPE)
                pthread_sigmask(SIG_BLOCK, &brokenPipe, &blocked)  // Linux has no per-pipe F_SETNOSIGPIPE
                defer {
                    var now = timespec()
                    while sigtimedwait(&brokenPipe, nil, &now) == SIGPIPE {}  // queued by a write to an ended tool
                    pthread_sigmask(SIG_SETMASK, &blocked, nil)
                }
            #endif
            try input.write(contentsOf: Data((line + "\n").utf8))
        }

        package func stop() {
            guard launched.process.isRunning else { return }  // a long-gone leader's number may belong to someone else
            Task { [launched] in await launched.end() }
        }

        package func status() async -> Int32 {
            await launched.exit.value
        }
    }

    fileprivate struct Launched: Sendable {
        let process: Process
        let exit: Task<Int32, Never>

        func end() async {
            deliver(SIGTERM)
            let grace = Task { try await Task.sleep(for: .seconds(1)) }
            Task {
                _ = await exit.value
                grace.cancel()
            }
            _ = await grace.result
            deliver(SIGKILL)
        }

        private func deliver(_ signal: Int32) {
            guard kill(-process.processIdentifier, signal) == -1, errno == ESRCH, process.isRunning else { return }
            kill(process.processIdentifier, signal)  // it does not lead a group of its own
        }
    }

    private static func launch(
        _ program: URL, _ arguments: [String], _ environment: [String: String],
        input: Any, output: Any, error: Any
    ) throws -> Launched {
        let (exits, exited) = AsyncStream.makeStream(of: Int32.self, bufferingPolicy: .bufferingNewest(1))
        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        process.terminationHandler = { exited.yield($0.terminationStatus) }
        do {
            try launching.withLock {
                var unblocked = sigset_t()
                var blocked = sigset_t()
                sigemptyset(&unblocked)
                pthread_sigmask(SIG_SETMASK, &unblocked, &blocked)  // inherited; pool threads block TERM
                defer { pthread_sigmask(SIG_SETMASK, &blocked, nil) }
                try process.run()
            }
        } catch {
            if isWorthRetrying(error) { throw FileBusy() }
            throw ToolError.missing
        }
        let exit = Task { await exits.first { _ in true }! }  // nothing cancels this task
        return Launched(process: process, exit: exit)
    }

    package static func isWorthRetrying(_ startFailure: any Error) -> Bool {
        let failure = startFailure as NSError
        let cause = failure.userInfo[NSUnderlyingErrorKey] as? NSError ?? failure
        return cause.domain == NSPOSIXErrorDomain && cause.code == Int(ETXTBSY)
    }

    private struct FileBusy: Error {}

    private static let launching = NSLock()  // on Linux a program inherits every descriptor made while it is spawned

    private static func newPipe() throws -> Pipe {
        try launching.withLock {
            let pipe = Pipe()
            #if os(Linux)
                for end in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
                    guard fcntl(end.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
            #endif
            return pipe
        }
    }

    private static func collect(_ handle: FileHandle) async -> Data {
        var collected = Data()
        for await chunk in chunks(of: handle) { collected.append(chunk) }
        return collected
    }

    private static func chunks(of handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(chunk)
                }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }  // a grandchild may keep it open
        }
    }
}
