import AppKit
import Carbon.HIToolbox
import SwiftUI

package final class PanelWindow {
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private weak var itemWindow: NSWindow?

    package init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationActivated), name: NSWorkspace.didActivateApplicationNotification,
            object: nil)
    }

    package var isOpen: Bool { panel != nil }
    package var onClose: (() -> Void)?
    package var closesOnItemClick: () -> Bool = { false }

    package func toggle(under button: NSStatusBarButton, showing model: AppModel) {
        if isOpen {
            close()
            return
        }
        guard let buttonWindow = button.window, let screen = buttonWindow.screen else { return }
        itemWindow = buttonWindow

        let item = buttonWindow.frame  // as tall as the menu bar, so its bottom edge is the bar's
        let top = item.minY - 4
        let frame = { (size: CGSize) in
            NSRect(x: item.maxX - size.width, y: top - size.height, width: size.width, height: size.height)
        }
        let hosting = NSHostingView(
            rootView: PanelView(maxHeight: top - screen.visibleFrame.minY - 12)
                .environment(model)
                .onGeometryChange(for: CGSize.self) {
                    $0.size
                } action: { [weak self] size in
                    self?.panel?.setFrame(frame(size), display: true)
                })
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        let panel = KeyPanel(
            contentRect: frame(size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.hidesOnDeactivate = false  // a panel that AppKit hides on its own would still count as open here

        let cornerRadius: CGFloat = 14
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: hosting.frame)
            glass.cornerRadius = cornerRadius
            glass.contentView = hosting
            panel.contentView = glass
        } else {
            let effect = NSVisualEffectView(frame: hosting.frame)
            effect.material = .menu
            effect.state = .active
            let corners = NSImage(
                size: NSSize(width: 2 * cornerRadius + 1, height: 2 * cornerRadius + 1), flipped: false
            ) { @Sendable bounds in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
                return true
            }
            corners.capInsets = NSEdgeInsets(
                top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
            corners.resizingMode = .stretch
            effect.maskImage = corners
            effect.addSubview(hosting)
            panel.contentView = effect
        }

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                guard let self else { return }
                let onItem = buttonWindow.frame.contains(NSEvent.mouseLocation)
                if !onItem || closesOnItemClick() { close() }  // a click on the item lands here too; its action closes
            },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                PanelWindow.keyDown(event, in: panel, showing: model) { self?.close() }
            },
        ].compactMap { $0 }
    }

    package static func keyDown(
        _ event: NSEvent, in panel: NSWindow, showing model: AppModel, close: () -> Void
    ) -> NSEvent? {
        guard event.windowNumber == panel.windowNumber else { return event }  // typed into Settings beside the panel
        let key = Int(event.keyCode)
        if key == kVK_Escape {
            close()
            return nil
        }
        let isPlain = event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift])
        guard isPlain, model.showsLists else { return event }  // the code field keeps its arrows and Return
        switch key {
        case kVK_DownArrow: model.moveSelection(by: 1)
        case kVK_UpArrow: model.moveSelection(by: -1)
        case kVK_Return, kVK_ANSI_KeypadEnter: model.openSelection()
        default: return event
        }
        return nil
    }

    package func close() {
        guard let panel else { return }
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        panel.orderOut(nil)
        self.panel = nil
        onClose?()
    }

    @objc private func applicationActivated(_ notification: Notification) {
        let leftButtonDown = NSEvent.pressedMouseButtons & 1 != 0
        let pressOnItem = leftButtonDown && itemWindow?.frame.contains(NSEvent.mouseLocation) == true
        if !pressOnItem { close() }  // on macOS 27 a press on the item can make another app active; its action closes
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
