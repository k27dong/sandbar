import SwiftUI

struct MenuBarPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section("Pull requests") {
                Picker("Titles", selection: $preferences.titles) {
                    Text("One line").tag(Preferences.Titles.oneLine)
                    Text("Two lines").tag(Preferences.Titles.twoLines)
                }
                Picker("Time", selection: $preferences.time) {
                    Text("Since opened").tag(Preferences.TimeShown.sinceOpened)
                    Text("Since last update").tag(Preferences.TimeShown.sinceUpdate)
                    Text("Off").tag(Preferences.TimeShown.off)
                }
                Toggle("Repository name", isOn: $preferences.showsRepository)
                Picker("Stacks", selection: $preferences.stackOrder) {
                    Text("Top branch first").tag(Preferences.StackOrder.topFirst)
                    Text("Bottom branch first").tag(Preferences.StackOrder.bottomFirst)
                }
            }
            Section("Usage") {
                Toggle(isOn: $preferences.showsPace) {
                    Text("Pace mark")
                    Text("A notch where even use would be by now")
                }
            }
        }
    }
}
