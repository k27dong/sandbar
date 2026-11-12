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

    package func toggle(under button: NSStatusBarButton, content: some View) {
        if isOpen {
            close()
            return
        }
        guard let buttonWindow = button.window else { return }
        itemWindow = buttonWindow

        let hosting = NSHostingView(rootView: content)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        let item = buttonWindow.frame  // as tall as the menu bar, so its bottom edge is the bar's
        let panel = KeyPanel(
            contentRect: NSRect(
                x: item.maxX - size.width, y: item.minY - 4 - size.height, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
                let onItem = buttonWindow.frame.contains(NSEvent.mouseLocation)
                if !onItem { self?.close() }  // on macOS 27 a click on the item lands here too, and its action closes
            },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if Int(event.keyCode) == kVK_Escape {
                    self?.close()
                    return nil
                }
                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "q" {
                    NSApplication.shared.terminate(nil)
                    return nil
                }
                return event
            },
        ].compactMap { $0 }
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
        let pressOnItem = NSEvent.pressedMouseButtons != 0 && itemWindow?.frame.contains(NSEvent.mouseLocation) == true
        if !pressOnItem { close() }  // on macOS 27 a press on the item can make another app active; its action closes
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
