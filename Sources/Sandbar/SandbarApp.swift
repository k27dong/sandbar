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

    private func togglePanel() {  // on its own: in the lazy item's closure Swift warns of an isolated conformance
        guard let model, let button = statusItem.button else { return }
        panel.toggle(under: button) { maxHeight in PanelView(maxHeight: maxHeight).environment(model) }
        statusItem.isHighlighted = panel.isOpen
        if panel.isOpen { model.panelOpened() }
    }

    private func use(_ model: AppModel) {
        model.closePanel = { [unowned self] in self.panel.close() }
        self.model = model
        showMenuBarItem()
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
