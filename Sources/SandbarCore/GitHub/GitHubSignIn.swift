import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

package struct GitHubSignIn: Sendable {
    package struct Code: Equatable, Sendable {
        package var userCode: String
        package var address: URL
        package var deviceCode: String
        package var interval: Duration
        package var expiresAt: Date
    }

    package enum Failure: Error, Equatable { case expired, denied }

    private static let deviceCodeAddress = URL(string: "https://github.com/login/device/code")!
    private static let tokenAddress = URL(string: "https://github.com/login/oauth/access_token")!

    private let clientID: String
    private let send: GitHubClient.Send
    private let sleep: @Sendable (Duration) async throws -> Void

    package init(
        clientID: String, send: @escaping GitHubClient.Send = GitHubClient.urlSession,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.clientID = clientID
        self.send = send
        self.sleep = sleep
    }

    package func start() async throws -> Code {
        struct Answer: Decodable {
            var deviceCode: String
            var userCode: String
            var verificationUri: URL
            var expiresIn: Int
            var interval: Int
        }
        let answer = try await post(["client_id": clientID, "scope": "repo"], to: Self.deviceCodeAddress)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let code: Answer
        do {
            code = try decoder.decode(Answer.self, from: answer)
        } catch is DecodingError {
            throw GitHubError.notUnderstood("unreadable device code answer")  // not quoted: it holds the code
        }
        return Code(
            userCode: code.userCode, address: code.verificationUri, deviceCode: code.deviceCode,
            interval: .seconds(code.interval), expiresAt: Date.now + TimeInterval(code.expiresIn))
    }

    package func token(for code: Code) async throws -> String {
        struct Answer: Decodable {
            var accessToken: String?
            var error: String?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let form = [
            "client_id": clientID, "device_code": code.deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ]
        var interval = code.interval
        while true {
            let answer: Answer
            do {
                answer = try decoder.decode(Answer.self, from: try await post(form, to: Self.tokenAddress))
            } catch is DecodingError {
                throw GitHubError.notUnderstood("device sign-in answer is not JSON")  // not quoted: may hold a token
            }
            switch (answer.accessToken, answer.error) {
            case (let token?, _): return token
            case (_, "authorization_pending"): break
            case (_, "slow_down"): interval += .seconds(5)
            case (_, "expired_token"): throw Failure.expired
            case (_, "access_denied"): throw Failure.denied
            case (_, let error):
                throw GitHubError.notUnderstood("device sign-in answered \(error ?? "neither a token nor an error")")
            }
            try await sleep(interval)
        }
    }

    package static func ghToken(gh: URL) async throws -> String {
        let output = try await Command.run(gh, ["auth", "token"])
        let token = String(decoding: output.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.status == 0, !token.isEmpty else { throw GitHubError.signedOut }
        return token
    }

    private func post(_ form: [String: String], to address: URL) async throws -> Data {
        var components = URLComponents()
        components.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: address)
        request.httpMethod = "POST"
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            return try await GitHubClient.answer(to: request, send: send)
        } catch GitHubError.rejected(let status, _) {
            throw GitHubError.rejected(status: status, body: "")  // not quoted: it may hold a code or a token
        }
    }
}
