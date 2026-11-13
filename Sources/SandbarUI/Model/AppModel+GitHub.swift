import AppKit
import SandbarCore

extension AppModel {

    package enum GitHubConnection: Equatable {
        case none
        case code(GitHubSignIn.Code)
        case connected(login: String, throughGh: Bool)
    }

    package static let gitHubClientID = "Ov23lia2Qs525DenxnCA"

    package var canUseGh: Bool { ghHasSignIn && !gitHubRefusedGh }

    package var needsGitHubSignIn: Bool {
        guard !isFixed else { return false }
        guard case .connected = gitHub else { return true }
        return snapshot.pullRequests.trouble == .signedOut
    }

    package var hiddenOrganizationsNote: String? {
        let names = snapshot.pullRequests.value.hiddenOrganizations
        return names.isEmpty ? nil : "Sandbar cannot see \(names.formatted(.list(type: .and)))."
    }

    var gitHubFailure: String? {
        let reading = snapshot.pullRequests
        let wasConnected = if case .connected = gitHub { true } else { false }
        let stoppedWorking = needsGitHubSignIn && reading.trouble == .signedOut && (isSetUp || wasConnected)
        return gitHubNote ?? (stoppedWorking ? reading.detail : nil)
    }

    func client(throughGh: Bool) -> GitHubClient? {
        guard !throughGh else {
            return gh.map { gh in
                GitHubClient(token: { try await GitHubSignIn.ghToken(gh: gh) }) {
                    @MainActor [weak self, send] request in
                    let (data, response) = try await send(request)
                    if response.statusCode == 401 { self?.gitHubRefusedGh = true }  // gh hands its token out unchecked
                    return (data, response)
                }
            }
        }
        return GitHubClient(
            token: { [keychain] in
                guard let token = try keychain.read() else { throw GitHubError.signedOut }
                return token
            }, send: send)
    }

    func signInToGitHub() async {
        if canUseGh { await useGhSignIn() } else { await connectGitHub() }
    }

    func copyCodeAndOpenGitHub(_ code: GitHubSignIn.Code) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.userCode, forType: .string)
        openGitHubForCode()
    }

    package func connectGitHub() async {
        await changingAccounts(.gitHubSignIn) { [self] in
            let before = gitHub
            gitHubNote = nil
            isWaitingForGitHub = false
            let signIn = GitHubSignIn(clientID: Self.gitHubClientID, send: send, sleep: sleep)
            do {
                let code = try await signIn.start()
                try Task.checkCancellation()
                gitHub = .code(code)
                let token = try await signIn.token(for: code)
                let login = try await GitHubClient(token: { token }, send: send).viewer()
                try Task.checkCancellation()
                try keychain.write(token)
                connected(as: login, throughGh: false)
            } catch {
                if case .code = gitHub { gitHub = before }
                guard !Task.isCancelled else { return }
                gitHubNote =
                    switch error {
                    case GitHubSignIn.Failure.expired: "The code expired."
                    case GitHubSignIn.Failure.denied: "The sign-in was cancelled on GitHub."
                    case is Keychain.Failure: "The sign-in could not be kept in the Keychain."
                    default: Snapshot.detail(of: error, tool: nil)
                    }
            }
        }
    }

    package func openGitHubForCode() {
        guard case .code(let code) = gitHub else { return }
        isWaitingForGitHub = true
        openAddress(code.address)
    }

    package func cancelGitHubSignIn() {
        guard case .code = gitHub else { return }
        accountAction?.task.cancel()
    }

    package func useGhSignIn() async {
        await changingAccounts(.gitHubSignIn) { [self] in
            gitHubNote = nil
            await toolLookupsEnded()
            do {
                guard let client = client(throughGh: true) else { throw GitHubError.signedOut }
                let login = try await client.viewer()
                try Task.checkCancellation()
                forgetKeptSignIn()
                connected(as: login, throughGh: true)
            } catch {
                guard !Task.isCancelled else { return }
                gitHubNote = Snapshot.detail(of: error, tool: nil)
            }
        }
    }

    package func signOutOfGitHub() {
        guard !isFixed else { return }
        if let accountAction, accountAction.kind == .gitHubSignIn { accountAction.task.cancel() }
        gitHubNote = nil
        forgetKeptSignIn()
        gitHub = .none
        pullRequestsReadOnce = false
        preferences.gitHubLogin = nil
        preferences.usesGhSignIn = false
        snapshot.pullRequests = Snapshot.empty.pullRequests
        saveSnapshot()
    }

    private func connected(as login: String, throughGh: Bool) {
        gitHub = .connected(login: login, throughGh: throughGh)
        pullRequestsReadOnce = false
        preferences.gitHubLogin = login
        preferences.usesGhSignIn = throughGh
        snapshot.pullRequests.trouble = nil
        snapshot.pullRequests.detail = nil
        owe(.pullRequests)
    }

    private func forgetKeptSignIn() {
        do {
            try keychain.delete()
        } catch {
            gitHubNote = "The sign-in could not be removed from the Keychain."
            Self.log.error("The GitHub sign-in stayed in the Keychain: \(String(describing: error), privacy: .public)")
        }
    }
}
