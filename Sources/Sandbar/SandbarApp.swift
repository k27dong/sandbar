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

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        let mainMenu = NSMenu()
        for (title, items) in [
            (
                "Sandbar",
                [
                    settings,
                    NSMenuItem(
                        title: "Quit Sandbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
                ]
            ),
            (
                "Edit",
                [
                    NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"), redo, .separator(),
                    NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
                    NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
                    NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
                    NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
                ]
            ),
            ("Window", [NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")]),
        ] {
            let menu = NSMenu(title: title)
            menu.items = items
            mainMenu.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        }
        NSApplication.shared.mainMenu = mainMenu  // never shown, with no menu bar of Sandbar's own; it routes the keys

        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--show") {
            guard arguments.indices.contains(flag + 1), FileManager.default.fileExists(atPath: arguments[flag + 1])
            else {
                FileHandle.standardError.write(Data("usage: Sandbar --show <a saved snapshot that exists>\n".utf8))
                exit(64)
            }
            use(AppModel(showing: URL(filePath: arguments[flag + 1])))
        } else {
            let model = AppModel(
                loginItem: ({ LoginItem.isOn }, LoginItem.set),
                banners: .system { [weak self] opens in
                    guard let self else { return }
                    switch opens {
                    case .pullRequest(let address): NSWorkspace.shared.open(address)
                    case .panel:
                        Task {
                            let deadline = ContinuousClock.now + .seconds(5)  // the item may not be placed yet
                            while statusItem.button?.window?.screen == nil, ContinuousClock.now < deadline {
                                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                            }
                            if !panel.isOpen { togglePanel() }
                        }
                    }
                })
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
        self.model = model
        showMenuBarItem()
        registerShortcut()
    }

    @objc private func openSettings() {
        model?.openSettings(nil)
    }

    private func registerShortcut() {
        guard let model else { return }
        withObservationTracking {
            shortcut = nil  // the old one lets go of its keys first, so the same keys can be taken again
            guard !model.isRecordingShortcut else { return }
            shortcut = model.preferences.shortcut.map { keys in Shortcut(keys) { [unowned self] in self.togglePanel() }
            }
            model.shortcutIsRefused = shortcut.map { !$0.isRegistered } ?? false
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
