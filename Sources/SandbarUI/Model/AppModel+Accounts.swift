import Foundation
import SandbarCore

extension AppModel {
    package enum GitHubConnection: Equatable {
        case none
        case code(GitHubSignIn.Code)
        case connected(login: String, throughGh: Bool)
    }
    package enum SignInStep: Equatable {
        case idle, fetching, waitingForBrowser
        case failed(String)
    }
    package nonisolated enum ExistingSignIn: Equatable, Sendable {
        case usable, absent
        case unreadable(String)
    }
    enum AccountAction { case gitHubSignIn, toolSignIn, removal }
    package static let gitHubClientID = "Ov23lia2Qs525DenxnCA"
    private static let notSavedNote = "Accounts could not be saved."

    package var isSetUp: Bool { isFixed || preferences.isSetUp }
    package var isChangingAccounts: Bool { accountAction != nil }
    package var isSigningIn: Bool { accountAction.map { $0.kind != .removal } ?? false }

    package var needsGitHubSignIn: Bool {
        guard !isFixed else { return false }
        guard case .connected = gitHub else { return true }
        return snapshot.pullRequests.trouble == .signedOut
    }

    package var hiddenOrganizationsNote: String? {
        let names = snapshot.pullRequests.value.hiddenOrganizations
        return names.isEmpty ? nil : "Sandbar cannot see \(names.formatted(.list(type: .and)))."
    }

    package var setupStatus: String {
        let connected =
            (needsGitHubSignIn ? 0 : 1) + Tool.allCases.count { tool in accounts.contains { $0.tool == tool } }
        return connected == 0 ? "Nothing connected" : "\(connected) of 3 connected"
    }

    package func connectGitHub() async {
        await changingAccounts(.gitHubSignIn) { [self] in
            let before = gitHub
            gitHubNote = nil
            isWaitingForGitHub = false
            let signIn = GitHubSignIn(clientID: Self.gitHubClientID, send: send, sleep: sleep)
            do {
                let code = try await signIn.start()
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
                forgetKeptSignIn()
                connected(as: login, throughGh: true)
            } catch {
                gitHubNote = Snapshot.detail(of: error, tool: nil)
            }
        }
    }

    package func signOutOfGitHub() {
        cancelGitHubSignIn()
        gitHubNote = nil
        forgetKeptSignIn()
        gitHub = .none
        preferences.gitHubLogin = nil
        preferences.usesGhSignIn = false
        snapshot.pullRequests = Snapshot.empty.pullRequests
        saveSnapshot()
    }

    package func canUseExisting(_ tool: Tool) -> Bool {
        existingSignIns[tool] == .usable && !accounts.contains { $0.tool == tool && $0.profile == nil }
    }

    package func useExisting(_ tool: Tool) async {
        await changingAccounts(.toolSignIn) { [self] in
            if keepsUnreadableAccounts, let accountsNote {
                signInStep[tool] = .failed(accountsNote)
                return
            }
            await toolLookupsEnded()
            do {
                guard let program = tools[tool], !fetchedTools.contains(tool) else { throw ToolError.missing }
                try await add(Account(tool: tool, name: tool.title, plan: "", profile: nil), signedInThrough: program)
                signInStep[tool] = .idle
            } catch {
                signInStep[tool] = .failed(Snapshot.detail(of: error, tool: tool))
            }
        }
    }

    package func addAccount(_ tool: Tool) async {
        await changingAccounts(.toolSignIn) { [self] in
            if keepsUnreadableAccounts, let accountsNote {
                signInStep[tool] = .failed(accountsNote)
                return
            }
            await toolLookupsEnded()
            defer { signInAddress = nil }
            do {
                let program: URL
                if let found = tools[tool] {
                    program = found
                } else {
                    signInStep[tool] = .fetching
                    program = try await download.install(tool)
                }
                let account = Account(
                    tool: tool, name: tool.title, plan: "", profile: try Account.makeProfile(in: files.profiles))
                do {
                    switch tool {
                    case .claude:
                        let running = try await ClaudeSignIn.begin(tool: program, environment: account.environment)
                        claudeSignIn = running
                        defer { claudeSignIn = nil }
                        signInStep[tool] = .waitingForBrowser
                        let reading = Task {
                            for await line in running.lines {
                                if let address = ClaudeSignIn.address(in: line) { signInAddress = address }
                            }
                        }
                        defer { reading.cancel() }
                        let status = await withTaskCancellationHandler {
                            await running.status()
                        } onCancel: {
                            running.stop()
                        }
                        guard status == 0 else { throw ToolError.failed(status: status, output: "") }
                    case .codex:
                        let pending = try await CodexSignIn.begin(tool: program, environment: account.environment)
                        signInAddress = pending.address
                        signInStep[tool] = .waitingForBrowser
                        openAddress(pending.address)
                        let finishing = Task { try await pending.finished() }
                        try await withTaskCancellationHandler {
                            try await finishing.value
                        } onCancel: {
                            Task { await pending.cancel() }  // the tool is told first; its end then ends the wait
                        }
                    }
                    try await add(account, signedInThrough: program)
                } catch {
                    if let folder = try account.profileToForget(in: files.profiles) {
                        try FileManager.default.removeItem(at: folder)
                    }
                    throw error
                }
                signInStep[tool] = .idle
            } catch {
                signInStep[tool] = Task.isCancelled ? .idle : .failed(Snapshot.detail(of: error, tool: tool))
            }
        }
    }

    package func pasteCode(_ code: String) {
        guard let claudeSignIn else { return }
        do {
            try claudeSignIn.send(code.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            claudeSignIn.stop()  // a tool that no longer reads is ended; its end fails the sign-in
        }
    }

    package func openSignInAgain() {
        if let signInAddress { openAddress(signInAddress) }
    }

    package func cancelSignIn(_ tool: Tool) {
        guard signInStep[tool] == .fetching || signInStep[tool] == .waitingForBrowser else { return }
        accountAction?.task.cancel()
    }

    /// Cancels the running sign-in and returns once its program has ended and its new profile folder is gone.
    package func endSignIn() async {
        guard isSigningIn else { return }
        accountAction?.task.cancel()
        await accountAction?.task.value
    }

    package func rename(_ account: Account, to name: String) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].name = name
        accountsChanged()
    }

    package func remove(_ account: Account) async {
        await changingAccounts(.removal) { [self] in
            guard accounts.contains(where: { $0.id == account.id }) else { return }
            await toolLookupsEnded()
            do {
                try await account.forget(tool: tools[account.tool], profiles: files.profiles)
                accounts.removeAll { $0.id == account.id }
                accountsChanged()
            } catch {
                signInStep[account.tool] = .failed(Snapshot.detail(of: error, tool: account.tool))
            }
        }
    }

    package func finishSetup() {
        preferences.isSetUp = true
    }

    private func changingAccounts(_ kind: AccountAction, _ work: @escaping () async -> Void) async {
        guard accountAction == nil else { return }
        let task = Task { await work() }
        accountAction = (task, kind)
        await task.value
        accountAction = nil
    }

    private func connected(as login: String, throughGh: Bool) {
        gitHub = .connected(login: login, throughGh: throughGh)
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

    private func add(_ account: Account, signedInThrough program: URL) async throws {
        let status = try await Self.status(of: account, through: program)
        guard status.isSignedIn else { throw ToolError.signedOut }
        var account = account
        account.name = status.organization ?? account.name
        account.plan = status.plan ?? ""
        accounts.append(account)
        accountsChanged()
    }

    private func accountsChanged() {
        do {
            try Account.save(accounts, to: files.accounts)
            if accountsNote == Self.notSavedNote { accountsNote = nil }
        } catch {
            accountsNote = Self.notSavedNote
            Self.log.error("The accounts were not saved: \(String(describing: error), privacy: .public)")
        }
        findTools()
        owe(.limits)
    }
}

extension Tool {
    var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}
