import AppKit
import Network
import Observation
import SandbarCore
import os

@Observable package final class AppModel {
    package struct Files: Sendable {
        package var snapshot: URL
        package var accounts: URL
        package var unreadableAccounts: URL
        package var profiles: URL
        package var tools: URL

        package init(folder: URL) {
            snapshot = folder.appending(path: "snapshot.json")
            accounts = folder.appending(path: "accounts.json")
            unreadableAccounts = folder.appending(path: "accounts.unreadable.json")
            profiles = folder.appending(path: "Profiles", directoryHint: .isDirectory)
            tools = folder.appending(path: "Tools", directoryHint: .isDirectory)
        }

        package static let standard = Files(
            folder: URL.applicationSupportDirectory.appending(path: "Sandbar", directoryHint: .isDirectory))
    }

    private nonisolated struct Listening: ~Copyable {
        var notices: NotificationCenter
        var observers: [any NSObjectProtocol]
        var network: NWPathMonitor

        deinit {
            for observer in observers { notices.removeObserver(observer) }
            network.cancel()
        }
    }

    package internal(set) var snapshot: Snapshot
    package internal(set) var accounts: [Account]
    package internal(set) var accountsNote: String?
    package private(set) var toolErrors: [Tool: any Error] = [:]
    package internal(set) var gitHub: GitHubConnection
    package internal(set) var gitHubNote: String?
    package internal(set) var isWaitingForGitHub = false
    package private(set) var existingSignIns: [Tool: ExistingSignIn] = [:]
    package internal(set) var signInStep: [Tool: SignInStep] = [.claude: .idle, .codex: .idle]
    package let preferences: Preferences
    package var now: Date
    package var openStacks: Set<Stack.ID> = []
    package var closePanel: () -> Void = {}
    package var openSettings: (SettingsWindow.Pane?) -> Void = { _ in }
    package private(set) var launchesAtLogin: Bool
    package private(set) var launchAtLoginNote: String?
    package var hasNetwork = true {
        didSet { if hasNetwork, !oldValue { refreshAtOnce() } }
    }

    static let log = Logger(subsystem: "com.k27dong.sandbar", category: "model")

    let files: Files
    let send: GitHubClient.Send
    let sleep: @Sendable (Duration) async throws -> Void
    let keychain: Keychain.Item
    let download: ToolDownload
    let openAddress: (URL) -> Void
    let loginItem: (isOn: () -> Bool, set: (Bool) throws -> Void)
    var accountAction: (task: Task<Void, Never>, kind: AccountAction)?
    var claudeSignIn: Command.Running?
    var signInAddress: URL?
    private(set) var tools: [Tool: URL] = [:]
    private(set) var fetchedTools: Set<Tool> = []
    private(set) var gh: URL?
    private(set) var ghHasSignIn = false
    private(set) var gitHubRefusedGh = false
    private(set) var keepsUnreadableAccounts = false
    private(set) var isFixed = false

    private let findTool: @Sendable (String) async -> URL?
    @ObservationIgnored private var toolLookup: Task<Void, Never>?
    @ObservationIgnored private var signInLookup: Task<Void, Never>?
    private var owed: Snapshot.Parts = []
    private var refreshesAsked = 0
    private var isReading = false
    private var copiesCheckedAt: Date?
    private var renewing: Set<Tool> = []
    private var renewedAfterFailure: Set<Tool> = []
    private var isAsleep = false
    private var isStarted = false
    @ObservationIgnored private var listening: Listening?

    package init(
        snapshot: Snapshot = .empty, preferences: Preferences = Preferences(), now: Date = .now,
        files: Files = .standard,
        findTool: @escaping @Sendable (String) async -> URL? = { await ToolLocation.find($0) },
        send: @escaping GitHubClient.Send = GitHubClient.urlSession,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        keychain: Keychain.Item = Keychain.Item(named: "github"),
        toolDownload: (URL) -> ToolDownload = ToolDownload.init(folder:),
        openAddress: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        loginItem: (isOn: () -> Bool, set: (Bool) throws -> Void) = ({ LoginItem.isOn }, LoginItem.set)
    ) {
        self.snapshot = snapshot
        accounts = snapshot.accounts.map(\.account)
        gitHub =
            preferences.gitHubLogin.map { GitHubConnection.connected(login: $0, throughGh: preferences.usesGhSignIn) }
            ?? .none
        self.preferences = preferences
        self.now = now
        self.files = files
        self.findTool = findTool
        self.send = send
        self.sleep = sleep
        self.keychain = keychain
        download = toolDownload(files.tools)
        self.openAddress = openAddress
        self.loginItem = loginItem
        launchesAtLogin = loginItem.isOn()
    }

    /// Shows a saved snapshot as it was when it was last asked for, and never refreshes it.
    package convenience init(showing file: URL) {
        let snapshot = SavedSnapshot.read(from: file)
        self.init(snapshot: snapshot, now: snapshot.lastAsked ?? .now)
        isFixed = true
    }

    package var list: PullRequestList {
        let lists = snapshot.pullRequests.value
        guard let chosen = preferences.chosenRepositories else {
            return PullRequestList(mine: lists.mine, reviewRequests: lists.reviewRequests)
        }
        return PullRequestList(
            mine: lists.mine.filter { chosen.contains($0.repository) },
            reviewRequests: lists.reviewRequests.filter { chosen.contains($0.repository) })
    }

    package var choosesRepositories: Bool {
        get { preferences.chosenRepositories != nil }
        set { preferences.chosenRepositories = newValue ? preferences.chosenRepositories ?? listedRepositories : nil }
    }

    /// Every repository with a pull request in either list now, and every chosen one, by name.
    package var repositoryChoices: [String] {
        Set(listedRepositories + (preferences.chosenRepositories ?? [])).sorted()
    }

    package func choose(_ repository: String, _ isChosen: Bool) {
        let others = (preferences.chosenRepositories ?? []).filter { $0 != repository }
        preferences.chosenRepositories = (isChosen ? others + [repository] : others).sorted()
    }

    private var listedRepositories: [String] {
        let lists = snapshot.pullRequests.value
        return Set((lists.mine + lists.reviewRequests).map(\.repository)).sorted()
    }

    package var isOffline: Bool {
        let trouble = snapshot.pullRequests.trouble
        return !hasNetwork || trouble == .offline || trouble == .failed
    }

    package var status: String {
        if isRefreshing { return "Updating…" }
        let offline = isOffline ? "Offline." : nil
        guard let readAt = snapshot.pullRequests.readAt else { return offline ?? "" }
        let age = now.timeIntervalSince(readAt) < 60 ? "just now" : "\(ShortTime.age(since: readAt, to: now)) ago"
        return [offline, "Updated \(age)"].compactMap(\.self).joined(separator: " ")
    }

    package var ring: StatusItem.Ring {
        guard !snapshot.accounts.isEmpty else { return .none }
        guard let fullest = snapshot.fullestLimit else { return .used(0, .normal) }
        return .used(fullest.used, fullest.level)
    }

    package func start() {
        guard !isStarted else { return }
        isStarted = true
        snapshot = SavedSnapshot.read(from: files.snapshot)
        do {
            accounts = try Account.load(from: files.accounts)
        } catch {
            accounts = []
            accountsNote = "Saved accounts could not be read."
            do {
                try FileManager.default.moveItem(at: files.accounts, to: files.unreadableAccounts)
            } catch {
                keepsUnreadableAccounts = true
            }
        }
        let notices = NSWorkspace.shared.notificationCenter
        let network = NWPathMonitor()
        network.pathUpdateHandler = { [weak self] path in
            let hasNetwork = path.status == .satisfied
            Task { @MainActor in self?.hasNetwork = hasNetwork }
        }
        network.start(queue: .main)
        listening = Listening(
            notices: notices,
            observers: [
                notices.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) {
                    [weak self] _ in
                    Task { @MainActor in self?.isAsleep = true }
                },
                notices.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) {
                    [weak self] _ in
                    Task { @MainActor in
                        self?.isAsleep = false
                        self?.refreshAtOnce()
                    }
                },
            ], network: network)
        if showsSignIn { findSignIns() } else { findTools() }
        refreshInBackground(.all)
        Task { [weak self] in
            while true {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                self.now = .now
                await self.refreshWhatIsDue()
            }
        }
    }

    package func refreshWhatIsDue() async {
        await toolLookupsEnded()
        if hasNetwork, !isAsleep, copiesCheckedAt.map({ now.timeIntervalSince($0) >= 86_400 }) ?? true {
            copiesCheckedAt = now
            for tool in fetchedTools {
                do {
                    if try download.isOld(tool, at: now) { renew(tool) }
                } catch {
                    toolErrors[tool] = error
                }
            }
        }
        let due = snapshot.due(at: now)
        if !due.isEmpty { await refresh(due) }
    }

    package func refresh(_ parts: Snapshot.Parts) async {
        refreshesAsked += 1
        defer { refreshesAsked -= 1 }
        await toolLookupsEnded()
        guard !isFixed, hasNetwork, !isAsleep, !isReading else { return }
        var parts = parts.union(owed)
        guard !parts.isEmpty else { return }
        isReading = true
        defer { isReading = false }
        repeat {
            owed = []
            let connection = gitHub
            let github: GitHubClient? =
                if case .connected(_, let throughGh) = connection { client(throughGh: throughGh) } else { nil }
            var read = await snapshot.refreshed(parts, github: github, accounts: accounts, tools: tools, now: now)
            if gitHub != connection { read.pullRequests = snapshot.pullRequests }  // signed out or in meanwhile
            snapshot = read
            saveSnapshot()
            for tool in fetchedTools {
                let failed = snapshot.accounts.contains { $0.account.tool == tool && $0.limits.trouble == .failed }
                if !failed {
                    renewedAfterFailure.remove(tool)
                } else if renewedAfterFailure.insert(tool).inserted {
                    renew(tool)
                }
            }
            await toolLookupsEnded()
            parts = owed
        } while !parts.isEmpty
    }

    /// Refreshes after the refresh in flight, if there is one: a change of accounts or sign-in is never dropped.
    func owe(_ parts: Snapshot.Parts) {
        owed.formUnion(parts)
        refreshInBackground([])
    }

    /// True from the moment a refresh is asked for until it has ended, the wait for a tool lookup included.
    package var isRefreshing: Bool { refreshesAsked > 0 }

    private func refreshInBackground(_ parts: Snapshot.Parts) {
        refreshesAsked += 1
        Task {
            await refresh(parts)
            refreshesAsked -= 1
        }
    }

    package func panelOpened() {
        if isStarted { now = .now }
        if showsSignIn { findSignIns() }
        if let asked = snapshot.lastAsked, now.timeIntervalSince(asked) < 15 { return }
        refreshInBackground(.all)
    }

    package func launchAtLogin(_ on: Bool) {
        do {
            try loginItem.set(on)
            launchAtLoginNote = nil
        } catch {
            launchAtLoginNote = "macOS did not change it: \(error.localizedDescription)"
            Self.log.error("Launch at login stayed as it was: \(String(describing: error), privacy: .public)")
        }
        launchesAtLogin = loginItem.isOn()
    }

    package func open(_ pullRequest: PullRequest) {
        openAddress(pullRequest.url)
        closePanel()
    }

    func saveSnapshot() {
        do {
            try SavedSnapshot.write(snapshot, to: files.snapshot)
        } catch {
            Self.log.error("The snapshot was not saved: \(String(describing: error), privacy: .public)")
        }
    }

    func findTools() {
        let earlier = toolLookup
        toolLookup = Task { [weak self, findTool, download] in
            await earlier?.value  // an earlier lookup that ends late must not overwrite this one
            async let gh = findTool("gh")
            let found = await withTaskGroup(of: (Tool, URL?).self) { group in
                for tool in Tool.allCases { group.addTask { (tool, await findTool(tool.rawValue)) } }
                var found: [Tool: URL] = [:]
                for await (tool, program) in group { found[tool] = program }
                return found
            }
            var tools = found
            var fetchedTools: Set<Tool> = []
            var toolErrors: [Tool: any Error] = [:]
            for tool in Tool.allCases where found[tool] == nil {
                do {
                    guard let copy = try download.installed(tool) else { continue }
                    tools[tool] = copy
                    fetchedTools.insert(tool)
                } catch {
                    toolErrors[tool] = error
                }
            }
            let foundGh = await gh
            self?.gh = foundGh
            self?.tools = tools
            self?.fetchedTools = fetchedTools
            self?.toolErrors = toolErrors
        }
    }

    func toolLookupsEnded() async {
        var waited: Task<Void, Never>?
        while waited != toolLookup {
            waited = toolLookup
            await waited?.value
        }
    }

    nonisolated static func status(of account: Account, through program: URL) async throws -> AccountStatus {
        switch account.tool {
        case .claude: try await ClaudeSignIn.status(tool: program, environment: account.environment)
        case .codex: try await CodexSignIn.status(tool: program, environment: account.environment)
        }
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

    private var showsSignIn: Bool { !isSetUp || needsGitHubSignIn }

    package func findSignIns() {
        findTools()
        let earlier = signInLookup
        signInLookup = Task { [weak self] in
            await earlier?.value
            await self?.toolLookupsEnded()
            guard
                let known = self.map({ model in
                    (gh: model.gh, own: model.tools.filter { !model.fetchedTools.contains($0.key) })
                })
            else { return }
            var ghHasSignIn = false
            if let gh = known.gh {
                do {
                    _ = try await GitHubSignIn.ghToken(gh: gh)
                    ghHasSignIn = true
                } catch {
                    if error as? GitHubError != .signedOut {
                        Self.log.error(
                            "gh could not say whether it is signed in: \(String(describing: error), privacy: .public)")
                    }
                }
            }
            let signIns = await withTaskGroup(of: (Tool, ExistingSignIn).self) { group in
                for tool in Tool.allCases {
                    group.addTask {
                        guard let program = known.own[tool] else { return (tool, .absent) }
                        do {
                            let status = try await Self.status(
                                of: Account(tool: tool, name: "", plan: "", profile: nil), through: program)
                            return (tool, status.isSignedIn ? .usable : .absent)
                        } catch {
                            return (tool, .unreadable(Snapshot.detail(of: error, tool: tool)))
                        }
                    }
                }
                var signIns: [Tool: ExistingSignIn] = [:]
                for await (tool, signIn) in group { signIns[tool] = signIn }
                return signIns
            }
            self?.ghHasSignIn = ghHasSignIn
            self?.existingSignIns = signIns
        }
    }

    private func renew(_ tool: Tool) {
        guard renewing.insert(tool).inserted else { return }
        Task { [weak self, download] in
            do {
                _ = try await download.install(tool)
                self?.findTools()
                self?.owe(.limits)
            } catch {
                self?.toolErrors[tool] = error
                let cause = String(describing: error)
                Self.log.error("\(tool.programName, privacy: .public) was not renewed: \(cause, privacy: .public)")
            }
            self?.renewing.remove(tool)
        }
    }

    private func refreshAtOnce() {
        if isStarted { now = .now }
        refreshInBackground(.all)
    }
}

extension Snapshot {
    fileprivate var lastAsked: Date? {
        ([pullRequests.askedAt] + accounts.map(\.limits.askedAt)).compactMap(\.self).max()
    }
}
