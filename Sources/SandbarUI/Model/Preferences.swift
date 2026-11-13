import Foundation
import Observation
import SandbarCore

@Observable package final class Preferences {
    package enum Titles: String { case oneLine, twoLines }
    package enum TimeShown: String { case sinceOpened, sinceUpdate, off }
    package enum StackOrder: String { case topFirst, bottomFirst }

    private enum Key {
        static let titles = "titles"
        static let time = "time"
        static let showsRepository = "showsRepository"
        static let stackOrder = "stackOrder"
        static let showsPace = "showsPace"
        static let chosenRepositories = "chosenRepositories"
        static let notificationsPaused = "notificationsPaused"
        static let isSetUp = "isSetUp"
        static let gitHubLogin = "gitHubLogin"
        static let usesGhSignIn = "usesGhSignIn"
    }

    private static let notificationKeys: [(key: String, isOn: WritableKeyPath<NotificationSettings, Bool>)] = [
        ("notifyApproved", \.approved), ("notifyChangesRequested", \.changesRequested),
        ("notifyChecksFailed", \.checksFailed), ("notifyLimitReset", \.limitReset),
        ("notifyReviewRequested", \.reviewRequested), ("notifyLimitNear", \.limitNear),
    ]

    package var titles: Titles { didSet { defaults.set(titles.rawValue, forKey: Key.titles) } }
    package var time: TimeShown { didSet { defaults.set(time.rawValue, forKey: Key.time) } }
    package var showsRepository: Bool { didSet { defaults.set(showsRepository, forKey: Key.showsRepository) } }
    package var stackOrder: StackOrder { didSet { defaults.set(stackOrder.rawValue, forKey: Key.stackOrder) } }
    package var showsPace: Bool { didSet { defaults.set(showsPace, forKey: Key.showsPace) } }
    package var chosenRepositories: [String]? {
        didSet { defaults.set(chosenRepositories, forKey: Key.chosenRepositories) }
    }
    package var notifications: NotificationSettings {
        didSet {
            for (key, isOn) in Self.notificationKeys { defaults.set(notifications[keyPath: isOn], forKey: key) }
        }
    }
    package var notificationsPaused: Bool {
        didSet { defaults.set(notificationsPaused, forKey: Key.notificationsPaused) }
    }
    package var isSetUp: Bool { didSet { defaults.set(isSetUp, forKey: Key.isSetUp) } }
    package var gitHubLogin: String? { didSet { defaults.set(gitHubLogin, forKey: Key.gitHubLogin) } }
    package var usesGhSignIn: Bool { didSet { defaults.set(usesGhSignIn, forKey: Key.usesGhSignIn) } }

    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        titles = defaults.string(forKey: Key.titles).flatMap(Titles.init(rawValue:)) ?? .oneLine
        time = defaults.string(forKey: Key.time).flatMap(TimeShown.init(rawValue:)) ?? .sinceOpened
        showsRepository = defaults.bool(forKey: Key.showsRepository)
        stackOrder = defaults.string(forKey: Key.stackOrder).flatMap(StackOrder.init(rawValue:)) ?? .topFirst
        showsPace = defaults.bool(forKey: Key.showsPace)
        chosenRepositories = defaults.stringArray(forKey: Key.chosenRepositories)
        var notifications = NotificationSettings()
        for (key, isOn) in Self.notificationKeys {
            if let stored = defaults.object(forKey: key) as? Bool { notifications[keyPath: isOn] = stored }
        }
        self.notifications = notifications
        notificationsPaused = defaults.bool(forKey: Key.notificationsPaused)
        isSetUp = defaults.bool(forKey: Key.isSetUp)
        gitHubLogin = defaults.string(forKey: Key.gitHubLogin)
        usesGhSignIn = defaults.bool(forKey: Key.usesGhSignIn)
    }
}
