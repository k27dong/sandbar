import Foundation

package actor CodexServer {
    package nonisolated let notices: AsyncStream<(method: String, parameters: Data)>
    private let running: Command.Running
    private let timeout: Duration
    private let announce: AsyncStream<(method: String, parameters: Data)>.Continuation
    private var waiting: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var nextID = 0
    private var endStatus: Int32?

    package init(tool: URL, environment: [String: String], timeout: Duration = .seconds(30)) async throws {
        running = try Command.start(
            tool, tool.lastPathComponent == "codex" ? ["app-server"] : [], environment: environment)
        self.timeout = timeout
        (notices, announce) = AsyncStream.makeStream()
        Task { [running] in
            for await line in running.lines { self.receive(line) }
            self.end(status: await running.status())
        }
        do {
            struct Client: Encodable, Sendable {
                struct Info: Encodable, Sendable {
                    var name = "sandbar"
                    var title = "Sandbar"
                    var version = "1"
                }
                var clientInfo = Info()
            }
            struct Ready: Decodable, Sendable {}
            struct Initialized: Encodable {
                var method = "initialized"
                var params: [String: String] = [:]
            }
            let _: Ready = try await ask("initialize", Client())
            try running.send(try Self.line(Initialized()))
        } catch {
            running.stop()
            throw error
        }
    }

    package func ask<Answer: Decodable & Sendable>(
        _ method: String, _ parameters: some Encodable & Sendable
    ) async throws -> Answer {
        if let endStatus { throw ToolError.failed(status: endStatus, output: "") }
        nextID += 1
        let id = nextID
        let question = try Self.line(Question(id: id, method: method, params: parameters))
        let timer = Task { [timeout] in
            try await Task.sleep(for: timeout)
            self.expire(id)
        }
        defer { timer.cancel() }
        let line = try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            do {
                try running.send(question)
            } catch {
                running.stop()  // a tool that no longer reads is ended; its end fails this question
            }
        }
        let reply: Reply<Answer>
        do {
            reply = try JSONDecoder().decode(Reply<Answer>.self, from: line)
        } catch is DecodingError {
            throw ToolError.notUnderstood(String(decoding: line.prefix(2_000), as: UTF8.self))
        }
        if let error = reply.error { throw ToolError.failed(status: error.code, output: error.message) }
        guard let result = reply.result else {
            throw ToolError.notUnderstood(String(decoding: line.prefix(2_000), as: UTF8.self))
        }
        return result
    }

    package func stop() {
        running.stop()
    }

    private struct Question<Parameters: Encodable>: Encodable {
        var id: Int
        var method: String
        var params: Parameters
    }

    private struct Reply<Answer: Decodable>: Decodable {
        struct Failure: Decodable {
            var code: Int32
            var message: String
        }
        var result: Answer?
        var error: Failure?
    }

    private func receive(_ line: String) {
        let data = Data(line.utf8)
        // a line that is not a JSON message answers nothing and announces nothing
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let method = message["method"] as? String,
            let parameters = try? JSONSerialization.data(
                withJSONObject: message["params"] ?? [String: Any](), options: .fragmentsAllowed)
        {
            announce.yield((method, parameters))
        } else if let id = message["id"] as? Int, let continuation = waiting.removeValue(forKey: id) {
            continuation.resume(returning: data)
        }
    }

    private func end(status: Int32) {
        endStatus = status
        for continuation in waiting.values {
            continuation.resume(throwing: ToolError.failed(status: status, output: ""))
        }
        waiting.removeAll()
        announce.finish()
    }

    private func expire(_ id: Int) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        running.stop()
        continuation.resume(throwing: ToolError.timedOut)
    }

    private static func line(_ message: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(message), as: UTF8.self)
    }
}
