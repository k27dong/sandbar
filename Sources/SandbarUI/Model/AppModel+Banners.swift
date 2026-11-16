import Foundation
import SandbarCore

extension AppModel {

    package var notificationsPaused: Bool {
        get { preferences.notificationsPaused }
        set {
            preferences.notificationsPaused = newValue
            scheduleResets()
        }
    }

    func scheduleResets() {
        var current = snapshot
        current.accounts.removeAll { entry in !accounts.contains { $0.id == entry.id } }  // still in the snapshot
        let resets =
            preferences.notificationsPaused
            ? [] : Banner.resets(in: current, settings: preferences.notifications, now: now)
        handOver { [banners] in await banners.schedule(resets) }
    }

    package func checkBanners() {
        Task { bannersAreOff = await !banners.isAllowed() }
    }

    package func openNotificationSettings() {
        let sandbar = Bundle.main.bundleIdentifier ?? ""
        openAddress(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(sandbar)")!)
    }

    /// Runs after everything handed over before it, and nobody waits for it: a slow macOS never holds up a refresh.
    func handOver(_ work: @escaping @MainActor () async -> Void) {
        let earlier = handingOver
        handingOver = Task {
            await earlier?.value
            await work()
        }
    }
}
