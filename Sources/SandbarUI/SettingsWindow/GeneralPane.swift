import AppKit
import Carbon.HIToolbox
import SwiftUI

struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    let version: String

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.launchesAtLogin }, set: { model.launchAtLogin($0) })) {
                    Text("Launch at login")
                    if let note = model.launchAtLoginNote { Text(note) }
                }
                LabeledContent("Open Sandbar with") { ShortcutButton() }
            }
            Section {
                Text("Version \(version)")
            }
        }
    }
}

private struct ShortcutButton: View {
    @Environment(AppModel.self) private var model
    @State private var keyWatch: Any?

    var body: some View {
        let keys = model.preferences.shortcut
        let button = Button {
            guard keyWatch == nil else { return stopWatching() }
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
        .onDisappear { stopWatching() }
    }

    private func stopWatching() {
        if let keyWatch { NSEvent.removeMonitor(keyWatch) }
        keyWatch = nil
    }
}
