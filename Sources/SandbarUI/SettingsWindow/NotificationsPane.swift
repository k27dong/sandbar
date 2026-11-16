import SwiftUI

struct NotificationsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.controlActiveState) private var windowState

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            if model.bannersAreOff {
                Section {
                    LabeledContent {
                        Button("Open System Settings…") { model.openNotificationSettings() }
                    } label: {
                        Text("Notifications are off for Sandbar.")
                    }
                }
            }
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
                FooterLine(text: "Sound, banner style and Focus are set in System Settings.")
            }
        }
        .onAppear { model.checkBanners() }
        .onChange(of: windowState) {
            if windowState == .key { model.checkBanners() }  // back from System Settings › Notifications
        }
    }
}
