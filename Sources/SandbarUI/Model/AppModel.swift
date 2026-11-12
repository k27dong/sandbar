import AppKit
import Network
import Observation
import SandbarCore
import os

@Observable package final class AppModel {
    package struct Files: Sendable {
        package var snapshot: URL
        package var accounts: URL
        package var profiles: URL
        package var tools: URL

        package init(folder: URL) {
            snapshot = folder.appending(path: "snapshot.json")
            accounts = folder.appending(path: "accounts.json")
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

    package private(set) var snapshot: Snapshot
    package private(set) var accounts: [Account]
    package private(set) var accountsError: (any Error)?
    package private(set) var toolErrors: [Tool: any Error] = [:]
    package let preferences: Preferences
    package var now: Date
    package private(set) var isRefreshing = false
    package var openStacks: Set<Stack.ID> = []
    package var closePanel: () -> Void = {}
    package var hasNetwork = true {
        didSet { if hasNetwork, !oldValue { refreshAtOnce() } }
    }

    private static let log = Logger(subsystem: "com.k27dong.sandbar", category: "snapshot")

    private let github: GitHubClient?
    private let files: Files
    private let findTool: @Sendable (String) async -> URL?
    private var tools: [Tool: URL] = [:]
    @ObservationIgnored private var toolLookup: Task<Void, Never>?
    private var isAsleep = false
    private var isStarted = false
    private var isFixed = false
    @ObservationIgnored private var listening: Listening?

    package init(
        snapshot: Snapshot = .empty, preferences: Preferences = Preferences(), now: Date = .now,
        github: GitHubClient? = nil, files: Files = .standard,
        findTool: @escaping @Sendable (String) async -> URL? = { await ToolLocation.find($0) }
    ) {
        self.snapshot = snapshot
        accounts = snapshot.accounts.map(\.account)
        self.preferences = preferences
        self.now = now
        self.github = github
        self.files = files
        self.findTool = findTool
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
            accountsError = error
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
        findTools()
        Task { [weak self] in
            await self?.refresh(.all)
            while true {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                self.now = .now
                await self.refreshWhatIsDue()
            }
        }
    }

    package func refreshWhatIsDue() async {
        let due = snapshot.due(at: now)
        if !due.isEmpty { await refresh(due) }
    }

    package func refresh(_ parts: Snapshot.Parts) async {
        await toolLookup?.value
        guard !isFixed, hasNetwork, !isAsleep, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        snapshot = await snapshot.refreshed(parts, github: github, accounts: accounts, tools: tools, now: now)
        do {
            try SavedSnapshot.write(snapshot, to: files.snapshot)
        } catch {
            Self.log.error("The snapshot was not saved: \(String(describing: error), privacy: .public)")
        }
    }

    package func panelOpened() {
        if isStarted { now = .now }
        if let asked = snapshot.lastAsked, now.timeIntervalSince(asked) < 15 { return }
        Task { await refresh(.all) }
    }

    package func open(_ pullRequest: PullRequest) {
        NSWorkspace.shared.open(pullRequest.url)
        closePanel()
    }

    private func findTools() {
        let accounts = accounts
        let earlier = toolLookup
        toolLookup = Task { [weak self, findTool, files] in
            await earlier?.value  // an earlier lookup that ends late must not overwrite this one
            var tools: [Tool: URL] = [:]
            var toolErrors: [Tool: any Error] = [:]
            for tool in Tool.allCases where accounts.contains(where: { $0.tool == tool }) {
                if let program = await findTool(tool.rawValue) {
                    tools[tool] = program
                    continue
                }
                do {
                    tools[tool] = try ToolDownload(folder: files.tools).installed(tool)
                } catch {
                    toolErrors[tool] = error
                }
            }
            self?.tools = tools
            self?.toolErrors = toolErrors
        }
    }

    private func refreshAtOnce() {
        if isStarted { now = .now }
        Task { await refresh(.all) }
    }
}

extension Snapshot {
    fileprivate var lastAsked: Date? {
        ([pullRequests.askedAt] + accounts.map(\.limits.askedAt)).compactMap(\.self).max()
    }
}
