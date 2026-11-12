import SwiftUI

struct NotificationsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section("Pull requests") {
                Toggle("Approved", isOn: $preferences.notifications.approved)
                Toggle("Changes requested", isOn: $preferences.notifications.changesRequested)
                Toggle("Checks failed", isOn: $preferences.notifications.checksFailed)
                Toggle("Your review requested", isOn: $preferences.notifications.reviewRequested)
            }
            Section {
                Toggle("Limit reset", isOn: $preferences.notifications.limitReset)
                Toggle("Close to a limit", isOn: $preferences.notifications.limitNear)
            } header: {
                Text("Usage")
            } footer: {
                Text("Sound, banner style and Focus are set in System Settings.")
            }
        }
    }
}
