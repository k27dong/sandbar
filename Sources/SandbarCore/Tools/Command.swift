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
        let output = Pipe()
        let error = Pipe()
        let process = try launch(
            program, arguments, environment, input: FileHandle.nullDevice, output: output, error: error)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Output?.self) { group in
                group.addTask {
                    async let standardOutput = readToEnd(output)
                    async let standardError = readToEnd(error)
                    let status = await process.exit.value
                    return Output(
                        status: status, standardOutput: await standardOutput, standardError: await standardError)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                defer { group.cancelAll() }
                guard case let finished?? = try await group.next() else {
                    process.end()
                    throw ToolError.timedOut
                }
                return finished
            }
        } onCancel: {
            process.end()
        }
    }

    package static func start(
        _ program: URL, _ arguments: [String] = [], environment: [String: String] = [:]
    ) throws -> Running {
        let input = Pipe()
        let output = Pipe()
        let process = try launch(
            program, arguments, environment, input: input, output: output, error: FileHandle.nullDevice)
        return Running(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading)
    }

    package final class Running: Sendable {
        package let lines: AsyncStream<String>
        private let process: Launched
        private let input: FileHandle

        fileprivate init(process: Launched, input: FileHandle, output: FileHandle) {
            self.process = process
            self.input = input
            lines = AsyncStream { continuation in
                Thread.detachNewThread {
                    var pending: [UInt8] = []
                    while case let chunk = output.availableData, !chunk.isEmpty {
                        pending.append(contentsOf: chunk)
                        while let end = pending.firstIndex(of: 0x0A) {
                            continuation.yield(String(decoding: pending[..<end], as: UTF8.self))
                            pending.removeSubrange(...end)
                        }
                    }
                    if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
                    continuation.finish()
                }
            }
        }

        package func send(_ line: String) throws {
            try input.write(contentsOf: Data((line + "\n").utf8))
        }

        package func stop() {
            process.end()
        }

        package func status() async -> Int32 {
            await process.exit.value
        }
    }

    fileprivate struct Launched: Sendable {
        let process: Process
        let exit: Task<Int32, Never>

        func end() {
            guard process.isRunning else { return }
            kill(-process.processIdentifier, SIGTERM)  // the group too: children can hold the output open
            process.terminate()
        }
    }

    private static func launch(
        _ program: URL, _ arguments: [String], _ environment: [String: String],
        input: Any, output: Any, error: Any
    ) throws -> Launched {
        signal(SIGPIPE, SIG_IGN)  // a tool that exits early must make `send` throw, not end Sandbar
        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        var unblocked = sigset_t()
        var blocked = sigset_t()
        sigemptyset(&unblocked)
        pthread_sigmask(SIG_SETMASK, &unblocked, &blocked)  // the program inherits it; worker threads block SIGTERM
        defer { pthread_sigmask(SIG_SETMASK, &blocked, nil) }
        do {
            try process.run()
        } catch {
            throw ToolError.missing
        }
        let exit = Task {
            await waitApart {
                process.waitUntilExit()
                return process.terminationStatus
            }
        }
        return Launched(process: process, exit: exit)
    }

    private static func readToEnd(_ pipe: Pipe) async -> Data {
        await waitApart { pipe.fileHandleForReading.readDataToEndOfFile() }
    }

    private static func waitApart<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: work()) }  // blocking waits starve shared threads
        }
    }
}
