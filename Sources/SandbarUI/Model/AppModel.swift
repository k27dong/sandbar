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

    package private(set) var snapshot: Snapshot
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
    private let network = NWPathMonitor()
    private var isAsleep = false
    private var isStarted = false
    private var isFixed = false

    package init(
        snapshot: Snapshot = .empty, preferences: Preferences = Preferences(), now: Date = .now,
        github: GitHubClient? = nil, files: Files = .standard
    ) {
        self.snapshot = snapshot
        self.preferences = preferences
        self.now = now
        self.github = github
        self.files = files
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

    package func start() {
        guard !isStarted else { return }
        isStarted = true
        snapshot = SavedSnapshot.read(from: files.snapshot)
        let notices = NSWorkspace.shared.notificationCenter
        _ = notices.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.isAsleep = true }
        }  // never taken back, like the one below: a started model listens for as long as the app runs
        _ = notices.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                self?.isAsleep = false
                self?.refreshAtOnce()
            }
        }
        network.pathUpdateHandler = { [weak self] path in
            let hasNetwork = path.status == .satisfied
            Task { @MainActor in self?.hasNetwork = hasNetwork }
        }
        network.start(queue: .main)
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
        guard !isFixed, hasNetwork, !isAsleep, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        snapshot = await snapshot.refreshed(parts, github: github, accounts: [], tools: [:], now: now)
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
