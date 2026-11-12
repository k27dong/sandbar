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

    private static let log = Logger(subsystem: "com.k27dong.sandbar", category: "snapshot")

    private let github: GitHubClient?
    private let files: Files
    private let network = NWPathMonitor()
    private var isOnline = true
    private var isAsleep = false
    private var followsTheClock = false
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
        return !isOnline || trouble == .offline || trouble == .failed
    }

    package var status: String {
        if isRefreshing { return "Updating…" }
        let offline = isOffline ? "Offline." : nil
        guard let readAt = snapshot.pullRequests.readAt else { return offline ?? "" }
        let age = now.timeIntervalSince(readAt) < 60 ? "just now" : "\(ShortTime.age(since: readAt, to: now)) ago"
        return [offline, "Updated \(age)"].compactMap(\.self).joined(separator: " ")
    }

    package func start() {
        snapshot = SavedSnapshot.read(from: files.snapshot)
        followsTheClock = true
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        network.pathUpdateHandler = { [weak self] path in
            let isOnline = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(isOnline: isOnline) }
        }
        network.start(queue: .main)
        Task {
            await refresh(.all)
            while true {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                now = .now
                let due = snapshot.due(at: now)
                if !isAsleep, isOnline, !due.isEmpty { await refresh(due) }
            }
        }
    }

    package func refresh(_ parts: Snapshot.Parts) async {
        guard !isFixed, !isRefreshing else { return }
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
        if followsTheClock { now = .now }
        if let asked = snapshot.lastAsked, now.timeIntervalSince(asked) < 15 { return }
        Task { await refresh(.all) }
    }

    package func open(_ pullRequest: PullRequest) {
        NSWorkspace.shared.open(pullRequest.url)
        closePanel()
    }

    @objc private func willSleep() {
        isAsleep = true
    }

    @objc private func didWake() {
        isAsleep = false
        refreshAtOnce()
    }

    private func networkChanged(isOnline: Bool) {
        let regained = isOnline && !self.isOnline
        self.isOnline = isOnline
        if regained { refreshAtOnce() }
    }

    private func refreshAtOnce() {
        now = .now
        Task { await refresh(.all) }
    }
}

extension Snapshot {
    fileprivate var lastAsked: Date? {
        ([pullRequests.askedAt] + accounts.map(\.limits.askedAt)).compactMap(\.self).max()
    }
}
