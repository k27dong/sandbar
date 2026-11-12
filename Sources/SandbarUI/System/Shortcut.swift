import AppKit
import Carbon.HIToolbox
import os

package final class Shortcut {
    package struct Keys: Codable, Equatable {
        package var keyCode: UInt32
        package var modifiers: UInt32

        package init(keyCode: UInt32, modifiers: UInt32) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        init?(_ event: NSEvent) {
            let marks: [(NSEvent.ModifierFlags, Int)] = [
                (.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey),
            ]
            let modifiers = marks.reduce(UInt32(0)) { sum, mark in
                event.modifierFlags.contains(mark.0) ? sum | UInt32(mark.1) : sum
            }
            self.init(taking: UInt32(event.keyCode), modifiers: modifiers)
        }

        /// Nil unless ⌃ or ⌥ is held: keys with only ⌘ and ⇧ belong to every app's own menus.
        package init?(taking keyCode: UInt32, modifiers: UInt32) {
            guard modifiers & UInt32(controlKey | optionKey) != 0 else { return nil }
            self.init(keyCode: keyCode, modifiers: modifiers)
        }

        package static let standard = Keys(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey | cmdKey))

        package var text: String {
            let marks = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            let held = marks.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined()
            return held + (Self.keyNames[Int(keyCode)] ?? "#\(keyCode)")
        }

        private static let keyNames: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
            kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`", kVK_Space: "Space", kVK_Return: "↩",
            kVK_Tab: "⇥", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_F1: "F1", kVK_F2: "F2",
            kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9",
            kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
    }

    private static let log = Logger(subsystem: "com.k27dong.sandbar", category: "shortcut")
    private static var lastID: UInt32 = 0

    private nonisolated struct Registration: ~Copyable {
        var hotKey: EventHotKeyRef?
        var handler: EventHandlerRef?

        deinit {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            if let handler { RemoveEventHandler(handler) }
        }
    }

    private let id: UInt32
    private let action: () -> Void
    private var registration: Registration?
    package private(set) var isRegistered = false

    package init(_ keys: Keys, action: @escaping () -> Void) {
        Self.lastID += 1
        id = Self.lastID
        self.action = action
        var hotKey: EventHotKeyRef?
        var handler: EventHandlerRef?
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, shortcut in
                var hotKey = EventHotKeyID()
                let read = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
                guard read == OSStatus(noErr), let shortcut else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {  // the system sends hot keys through the main run loop
                    let shortcut = Unmanaged<Shortcut>.fromOpaque(shortcut).takeUnretainedValue()
                    guard hotKey.id == shortcut.id else { return OSStatus(eventNotHandledErr) }  // another shortcut's
                    shortcut.action()
                    return OSStatus(noErr)
                }
            }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let registered = RegisterEventHotKey(
            keys.keyCode, keys.modifiers, EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(),
            0, &hotKey)
        registration = Registration(hotKey: hotKey, handler: handler)
        isRegistered = installed == OSStatus(noErr) && registered == OSStatus(noErr)
        if !isRegistered {
            let statuses = "\(installed), \(registered)"
            Self.log.error("\(keys.text, privacy: .public) was not registered: \(statuses, privacy: .public)")
        }
    }

    private static let signature = OSType(0x5342_4152)  // "SBAR"
}
