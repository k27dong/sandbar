import AppKit
import SandbarUI

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
    private lazy var statusItem: StatusItem = StatusItem { [unowned self] in
        guard let button = self.statusItem.button else { return }
        self.panel.toggle(under: button, content: PanelView())
        self.statusItem.isHighlighted = self.panel.isOpen
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.onClose = { [unowned self] in self.statusItem.isHighlighted = false }
        statusItem.show(ring: .none, count: 0, dimmed: false)
    }
}
