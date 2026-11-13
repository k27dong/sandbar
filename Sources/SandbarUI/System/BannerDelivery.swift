import Foundation
import SandbarCore
import UserNotifications

package struct BannerDelivery: Sendable {
    package var deliver: @MainActor ([Banner]) async -> Void
    package var schedule: @MainActor ([Banner]) async -> Void  // replaces every reset banner handed over before
    package var askPermission: @MainActor () async -> Void

    package init(
        deliver: @escaping @MainActor ([Banner]) async -> Void,
        schedule: @escaping @MainActor ([Banner]) async -> Void,
        askPermission: @escaping @MainActor () async -> Void
    ) {
        self.deliver = deliver
        self.schedule = schedule
        self.askPermission = askPermission
    }

    package static let none = BannerDelivery(deliver: { _ in }, schedule: { _ in }, askPermission: {})

    /// Needs an app bundle: macOS raises when a program without one asks for its notification center.
    package static func system(onOpen: @escaping @MainActor (Banner.Opens) -> Void) -> BannerDelivery {
        let banners = SystemBanners(onOpen: onOpen)
        UNUserNotificationCenter.current().delegate = banners  // held weakly there; the closures below keep it
        return BannerDelivery(
            deliver: banners.deliver, schedule: banners.schedule, askPermission: banners.askPermission)
    }
}

private final class SystemBanners: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let addressKey = "pullRequest"
    private let onOpen: @MainActor (Banner.Opens) -> Void
    private var saidRefused = false

    init(onOpen: @escaping @MainActor (Banner.Opens) -> Void) {
        self.onOpen = onOpen
    }

    func deliver(_ banners: [Banner]) async {
        guard await isAllowed() else { return }
        for banner in banners { await add(banner) }
    }

    func schedule(_ banners: [Banner]) async {
        let center = UNUserNotificationCenter.current()
        let kept = Set(banners.map(\.id))
        let pending = await center.pendingNotificationRequests()
        let stale = pending.filter { request in
            request.trigger != nil && !kept.contains(request.identifier)  // a banner for now has no trigger
        }
        center.removePendingNotificationRequests(withIdentifiers: stale.map(\.identifier))
        guard await isAllowed() else { return }
        for banner in banners { await add(banner) }
    }

    func askPermission() async {
        do {
            let isAllowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            if !isAllowed { AppModel.log.notice("Banners are not allowed for Sandbar") }
        } catch {
            AppModel.log.error("Permission for banners was not asked: \(String(describing: error), privacy: .public)")
        }
    }

    /// Asks macOS each time, so a switch turned on later in System Settings counts at once.
    private func isAllowed() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let isAllowed = status == .authorized || status == .provisional
        if !isAllowed, !saidRefused { AppModel.log.notice("Banners are not allowed for Sandbar; none is handed over") }
        saidRefused = !isAllowed
        return isAllowed
    }

    private func add(_ banner: Banner) async {
        let content = UNMutableNotificationContent()
        content.title = banner.title
        content.body = banner.body
        content.sound = .default
        if case .pullRequest(let address) = banner.opens {
            content.userInfo = [Self.addressKey: address.absoluteString]  // it travels with the banner past a relaunch
        }
        var trigger: UNCalendarNotificationTrigger?
        if let moment = banner.deliverAt {
            let parts = Calendar.current.dateComponents(
                [.timeZone, .year, .month, .day, .hour, .minute, .second], from: moment)  // the zone pins the moment
            trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        }
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: banner.id, content: content, trigger: trigger))
        } catch {
            let cause = String(describing: error)
            AppModel.log.error("macOS refused the banner \(banner.id, privacy: .public): \(cause, privacy: .public)")
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let address = response.notification.request.content.userInfo[Self.addressKey] as? String
        await onOpen(address.flatMap(URL.init(string:)).map(Banner.Opens.pullRequest) ?? .panel)
    }
}
