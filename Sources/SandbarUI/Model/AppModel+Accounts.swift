import AppKit
import SandbarCore

extension AppModel {

    package enum SignInStep: Equatable {
        case idle, fetching, waitingForBrowser
        case failed(String)
    }
    package nonisolated enum ExistingSignIn: Equatable, Sendable {
        case usable, absent
        case unreadable(String)
    }
    enum AccountAction { case gitHubSignIn, toolSignIn, removal }

    private static let notSavedNote = "Accounts could not be saved."

    package var isSetUp: Bool { isFixed || preferences.isSetUp }
    var showsLists: Bool {
        if case .code = gitHub { return false }
        return isSetUp
    }
    package var accountsAreLocked: Bool { isFixed || accountAction != nil }
    package var canRenameAccounts: Bool { !isFixed }
    package var isSigningIn: Bool { accountAction.map { $0.kind != .removal } ?? false }

    package var setupStatus: String {
        let connected =
            (needsGitHubSignIn ? 0 : 1) + Tool.allCases.count { tool in accounts.contains { $0.tool == tool } }
        return connected == 0 ? "Nothing connected" : "\(connected) of 3 connected"
    }

    package func signInTrouble(_ tool: Tool) -> String? {
        if case .failed(let sentence) = signInStep[tool] { return sentence }
        if case .unreadable(let sentence) = existingSignIns[tool] { return sentence }
        return nil
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
                    do {
                        program = try await download.install(tool)
                    } catch {
                        throw DownloadError.failed(String(describing: error))  // any cause reads as a failed fetch
                    }
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
                } catch {
                    try await account.forget(tool: nil, profiles: files.profiles)
                    throw error
                }
                do {
                    try await add(account, signedInThrough: program)
                } catch {  // the tool has signed in by now, and may keep that sign-in outside the folder
                    let signOut = Task {  // of its own: a Cancel would end the sign-out with this task
                        try await account.forget(tool: program, profiles: files.profiles)
                    }
                    do {
                        try await signOut.value
                    } catch let failure {
                        Self.log.error("A sign-in that was not kept stayed signed in: \(String(describing: failure))")
                        try await account.forget(tool: nil, profiles: files.profiles)
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
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canRenameAccounts, !name.isEmpty, let index = accounts.firstIndex(where: { $0.id == account.id }) else {
            return
        }
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
        guard !preferences.isSetUp else { return }
        preferences.isSetUp = true
        launchAtLogin(true)
        Task { await banners.askPermission() }
    }

    func changingAccounts(_ kind: AccountAction, _ work: @escaping () async -> Void) async {
        guard !accountsAreLocked else { return }
        let task = Task { await work() }
        accountAction = (task, kind)
        await task.value
        accountAction = nil
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
        scheduleResets()
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
