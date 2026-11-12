import AppKit
import Observation
import SandbarCore
import SandbarUI
import SwiftUI

@main
enum SandbarApp {
    static func main() {
        let delegate = AppDelegate()
        let application = NSApplication.shared
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }  // the application holds its delegate weakly
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let panel = PanelWindow()
    private var model: AppModel?
    private var shortcut: Shortcut?
    private lazy var statusItem = StatusItem { [unowned self] in self.togglePanel() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.onClose = { [unowned self] in self.statusItem.isHighlighted = false }
        statusItem.show(ring: .none, count: nil, dimmed: false)

        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--show") {
            guard arguments.indices.contains(flag + 1), FileManager.default.fileExists(atPath: arguments[flag + 1])
            else {
                FileHandle.standardError.write(Data("usage: Sandbar --show <a saved snapshot that exists>\n".utf8))
                exit(64)
            }
            use(AppModel(showing: URL(filePath: arguments[flag + 1])))
        } else {
            let model = AppModel()
            use(model)
            model.start()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isSigningIn else { return .terminateNow }
        Task {
            await model.endSignIn()  // a tool's sign-in waits for a browser with no end, and nobody else would end it
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func togglePanel() {  // on its own: in the lazy item's closure Swift warns of an isolated conformance
        guard let model, let button = statusItem.button else { return }
        panel.toggle(under: button) { maxHeight in PanelView(maxHeight: maxHeight).environment(model) }
        statusItem.isHighlighted = panel.isOpen
        if panel.isOpen { model.panelOpened() }
    }

    private func use(_ model: AppModel) {
        let settings = SettingsWindow(model: model)
        model.closePanel = { [unowned self] in self.panel.close() }
        model.openSettings = { [unowned self] pane in
            self.panel.close()
            settings.show(pane)
        }
        panel.openSettings = { model.openSettings(nil) }
        self.model = model
        showMenuBarItem()
        registerShortcut()
    }

    private func registerShortcut() {
        guard let model else { return }
        withObservationTracking {
            shortcut = nil  // the old one lets go of its keys first, so the same keys can be taken again
            shortcut = model.preferences.shortcut.map { keys in Shortcut(keys) { [unowned self] in self.togglePanel() }
            }
        } onChange: {
            Task { @MainActor in self.registerShortcut() }
        }
    }

    private func showMenuBarItem() {
        guard let model else { return }
        withObservationTracking {
            statusItem.show(
                ring: model.ring, count: model.snapshot.pullRequests.readAt == nil ? nil : model.list.openCount,
                dimmed: model.isOffline)
        } onChange: {
            Task { @MainActor in self.showMenuBarItem() }
        }
    }
}
