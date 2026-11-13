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
    package internal(set) var toolErrors: [Tool: any Error] = [:]
    package internal(set) var gitHub: GitHubConnection
    package internal(set) var gitHubNote: String?
    package internal(set) var isWaitingForGitHub = false
    package internal(set) var existingSignIns: [Tool: ExistingSignIn] = [:]
    package internal(set) var signInStep: [Tool: SignInStep] = [.claude: .idle, .codex: .idle]
    package let preferences: Preferences
    package var now: Date
    package var openStacks: Set<Stack.ID> = []
    package var selection: PullRequestList.Selection?
    package var closePanel: () -> Void = {}
    package var openSettings: (SettingsWindow.Pane?) -> Void = { _ in }
    package internal(set) var launchesAtLogin: Bool
    package internal(set) var launchAtLoginNote: String?
    package var isRecordingShortcut = false
    package var shortcutIsRefused = false
    package var hasNetwork = true {
        didSet { if hasNetwork, !oldValue { refreshAtOnce() } }
    }

    package static let log = Logger(subsystem: "com.k27dong.sandbar", category: "model")

    let files: Files
    let send: GitHubClient.Send
    let sleep: @Sendable (Duration) async throws -> Void
    let keychain: Keychain.Item
    let download: ToolDownload
    let openAddress: (URL) -> Void
    let loginItem: (isOn: () -> Bool, set: (Bool) throws -> Void)
    let banners: BannerDelivery
    var accountAction: (task: Task<Void, Never>, kind: AccountAction)?
    var claudeSignIn: Command.Running?
    var signInAddress: URL?
    var tools: [Tool: URL] = [:]
    var fetchedTools: Set<Tool> = []
    var gh: URL?
    var ghHasSignIn = false
    var gitHubRefusedGh = false
    private(set) var keepsUnreadableAccounts = false
    private(set) var isFixed = false

    let findTool: @Sendable (String) async -> URL?
    @ObservationIgnored var toolLookup: Task<Void, Never>?
    @ObservationIgnored var signInLookup: Task<Void, Never>?
    private var owed: Snapshot.Parts = []
    var pullRequestsReadOnce = false  // until the first good answer of this run, what is shown is old news
    private var accountsReadOnce: Set<Account.ID> = []
    @ObservationIgnored var handingOver: Task<Void, Never>?
    private var refreshesAsked = 0
    private var isReading = false
    private var copiesCheckedAt: Date?
    var renewing: Set<Tool> = []
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
        loginItem: (isOn: () -> Bool, set: (Bool) throws -> Void) = ({ false }, { _ in }),
        banners: BannerDelivery = .none
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
        self.banners = banners
        launchesAtLogin = loginItem.isOn()
    }

    /// Shows a saved snapshot as it was when it was last asked for, never refreshes it, and changes nothing real.
    package convenience init(
        showing file: URL, files: Files = .standard, keychain: Keychain.Item = Keychain.Item(named: "github"),
        findTool: @escaping @Sendable (String) async -> URL? = { await ToolLocation.find($0) },
        send: @escaping GitHubClient.Send = GitHubClient.urlSession,
        toolDownload: (URL) -> ToolDownload = ToolDownload.init(folder:)
    ) {
        let snapshot = SavedSnapshot.read(from: file)
        let defaults = UserDefaults(suiteName: Self.shownSuite)!  // nil only for the app's own or the global domain
        defaults.removePersistentDomain(forName: Self.shownSuite)
        self.init(
            snapshot: snapshot, preferences: Preferences(defaults: defaults), now: snapshot.lastAsked ?? .now,
            files: files, findTool: findTool, send: send, keychain: keychain, toolDownload: toolDownload)
        isFixed = true
    }

    private static let shownSuite = "com.k27dong.sandbar.shown"

    package var list: PullRequestList {
        let lists = snapshot.pullRequests.value.only(in: preferences.chosenRepositories)
        return PullRequestList(mine: lists.mine, reviewRequests: lists.reviewRequests)
    }

    package var isOffline: Bool {
        let trouble = snapshot.pullRequests.trouble
        return !hasNetwork || trouble == .offline || trouble == .failed
    }

    package var status: String {
        snapshot.status(at: now, isRefreshing: isRefreshing, isOffline: isOffline)
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
            let isSameGitHub = gitHub == connection
            if !isSameGitHub { read.pullRequests = snapshot.pullRequests }  // signed out or in meanwhile
            var old = snapshot
            old.accounts.removeAll { !accountsReadOnce.contains($0.id) }  // the core is silent about one it lacks
            let changes = read.changes(since: old, in: pullRequestsReadOnce ? parts : parts.subtracting(.pullRequests))
            if parts.contains(.pullRequests), isSameGitHub, read.pullRequests.trouble == nil {
                pullRequestsReadOnce = true
            }
            if parts.contains(.limits) {
                accountsReadOnce.formUnion(read.accounts.filter { $0.limits.trouble == nil }.map(\.id))
            }
            snapshot = read
            saveSnapshot()
            if !preferences.notificationsPaused {
                let fresh = Banner.now(for: changes, settings: preferences.notifications, at: now)
                if !fresh.isEmpty { handOver { [banners] in await banners.deliver(fresh) } }
            }
            scheduleResets()
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
        selection = nil
        if isStarted { now = .now }
        if showsSignIn { findSignIns() }
        if let asked = snapshot.lastAsked, now.timeIntervalSince(asked) < 15 { return }
        refreshInBackground(.all)
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

    private var showsSignIn: Bool { !isSetUp || needsGitHubSignIn }

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
