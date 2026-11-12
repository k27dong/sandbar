import AppKit
import SwiftUI

package final class SettingsWindow {
    package enum Pane: String, CaseIterable { case general, menuBar, accounts, notifications }

    private let model: AppModel
    private lazy var tabs = PaneTabs(model: model)
    private lazy var window: NSWindow = {
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        return window
    }()

    package init(model: AppModel) {
        self.model = model
    }

    package func show(_ pane: Pane? = nil) {
        let pane = pane ?? model.preferences.settingsPane  // before the tabs exist: building them selects the first
        let window = window
        tabs.show(pane)
        if !window.isVisible { window.center() }
        NSApplication.shared.activate(ignoringOtherApps: true)  // a plain activate() waits for the active app to yield
        window.makeKeyAndOrderFront(nil)
    }
}

extension SettingsWindow.Pane {
    fileprivate var title: String {
        switch self {
        case .general: "General"
        case .menuBar: "Menu Bar"
        case .accounts: "Accounts"
        case .notifications: "Notifications"
        }
    }

    fileprivate var symbol: String {
        switch self {
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .accounts: "person.crop.circle"
        case .notifications: "bell"
        }
    }
}

private final class PaneTabs: NSTabViewController {
    private let preferences: Preferences

    init(model: AppModel) {
        preferences = model.preferences
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        for pane in SettingsWindow.Pane.allCases {
            let host = NSHostingController(rootView: SettingsView(pane: pane, version: version).environment(model))
            host.sizingOptions = .preferredContentSize
            host.title = pane.title  // the tabs give the selected one's title to the window
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)
            addTabViewItem(item)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Settings are never loaded from a file") }

    func show(_ pane: SettingsWindow.Pane) {
        selectedTabViewItemIndex = SettingsWindow.Pane.allCases.firstIndex(of: pane) ?? 0
        fit()
    }

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        preferences.settingsPane = SettingsWindow.Pane.allCases[selectedTabViewItemIndex]
        fit()
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        fit()
    }

    private func fit() {
        guard let window = view.window, let pane = tabViewItems[selectedTabViewItemIndex].viewController else { return }
        let size = pane.preferredContentSize
        guard size.height > 0 else { return }
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        let top = window.frame.maxY  // the top edge stays put, as in the Mac's own settings windows
        window.setFrame(
            NSRect(x: window.frame.minX, y: top - frame.height, width: frame.width, height: frame.height),
            display: true,
            animate: window.isVisible)
    }
}

package struct SettingsView: View {
    private let pane: SettingsWindow.Pane
    private let version: String?

    package init(pane: SettingsWindow.Pane, version: String?) {
        self.pane = pane
        self.version = version
    }

    package var body: some View {
        Group {
            switch pane {
            case .general: GeneralPane(version: version)
            case .menuBar: MenuBarPane()
            case .accounts: AccountsPane()
            case .notifications: NotificationsPane()
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollDisabled(true)
        .frame(width: 500)
    }
}

struct FooterLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)  // a window puts a footer at its trailing edge
    }
}
