import AppKit
import SandbarCore

extension AppModel {

    package var choosesRepositories: Bool {
        get { preferences.chosenRepositories != nil }
        set {
            preferences.chosenRepositories =
                newValue ? preferences.chosenRepositories ?? snapshot.pullRequests.value.repositories : nil
        }
    }

    package var repositoryChoices: [String] {
        Set(snapshot.pullRequests.value.repositories + (preferences.chosenRepositories ?? [])).sorted()
    }

    package func choose(_ repository: String, _ isChosen: Bool) {
        let others = (preferences.chosenRepositories ?? []).filter { $0 != repository }
        preferences.chosenRepositories = (isChosen ? others + [repository] : others).sorted()
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

    package func checkLaunchAtLogin() {
        launchesAtLogin = loginItem.isOn()
    }
}
