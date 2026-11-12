import AppKit
import Carbon.HIToolbox
import SwiftUI

struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    let version: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.launchesAtLogin }, set: { model.launchAtLogin($0) })) {
                    Text("Launch at login")
                    if let note = model.launchAtLoginNote { Text(note) }
                }
                .disabled(model.isFixed)
                LabeledContent {
                    ShortcutButton()
                } label: {
                    Text("Open Sandbar with")
                    if model.shortcutIsRefused { Text("This shortcut is not available.") }
                }
            }
            if let version {
                Section {
                    Text("Version \(version)")
                }
            }
        }
        .onAppear { model.checkLaunchAtLogin() }
    }
}

private struct ShortcutButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.controlActiveState) private var windowState
    @State private var keyWatch: Any?

    var body: some View {
        let keys = model.preferences.shortcut
        let button = Button {
            guard keyWatch == nil else { return stopWatching() }
            model.isRecordingShortcut = true  // the present shortcut lets go of its keys, so they can be pressed again
            keyWatch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch Int(event.keyCode) {
                case kVK_Escape: break
                case kVK_Delete, kVK_ForwardDelete: model.preferences.shortcut = nil
                default:
                    guard let keys = Shortcut.Keys(event) else { return nil }
                    model.preferences.shortcut = keys
                }
                stopWatching()
                return nil
            }
        } label: {
            Text(keys?.text ?? "none")
                .foregroundStyle(keys == nil ? .secondary : .primary)
        }
        Group {
            if keyWatch == nil { button.buttonStyle(.bordered) } else { button.buttonStyle(.borderedProminent) }
        }
        .onChange(of: windowState) {
            if windowState != .key { stopWatching() }
        }
        .onDisappear { stopWatching() }
    }

    private func stopWatching() {
        if let keyWatch { NSEvent.removeMonitor(keyWatch) }
        keyWatch = nil
        model.isRecordingShortcut = false
    }
}
