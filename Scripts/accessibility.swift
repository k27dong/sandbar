import ApplicationServices
import Foundation

func attribute(_ name: String, of element: AXUIElement) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func text(_ name: String, of element: AXUIElement) -> String? {
    switch attribute(name, of: element) {
    case let plain as String: plain
    case let styled as NSAttributedString: styled.string
    default: nil
    }
}

func descendants(of element: AXUIElement) -> [AXUIElement] {
    let children = attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
    return children.flatMap { [$0] + descendants(of: $0) }
}

func stop(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(status)
}

let label = "AXAttributedDescription"  // the one attribute SwiftUI puts an element's label in
let usage = "usage: accessibility <process id> list | has|press|value|frame <label, title, value or role>"
let arguments = CommandLine.arguments
guard arguments.count >= 3, let program = pid_t(arguments[1]) else { stop(usage, status: 64) }
guard AXIsProcessTrusted() else { stop("macOS does not let this program use the accessibility API", status: 1) }
let windows = attribute(kAXWindowsAttribute, of: AXUIElementCreateApplication(program)) as? [AXUIElement] ?? []
let elements = windows.flatMap { descendants(of: $0) }

if arguments[2] == "list" {
    for element in elements {
        let parts = [
            text(kAXRoleAttribute, of: element), text(label, of: element), text(kAXTitleAttribute, of: element),
            text(kAXValueAttribute, of: element).map { "value \($0)" },
            attribute(kAXSelectedAttribute, of: element) as? Bool == true ? "selected" : nil,
        ]
        print(parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " | "))
    }
    exit(0)
}

guard arguments.count == 4 else { stop(usage, status: 64) }
let names = [label, kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute, kAXRoleAttribute]
guard let found = elements.first(where: { element in names.contains { text($0, of: element) == arguments[3] } }) else {
    stop("no \(arguments[3]) in the windows of process \(program)", status: 1)
}
switch arguments[2] {
case "has": break
case "press":
    let result = AXUIElementPerformAction(found, kAXPressAction as CFString)
    guard result == .success else { stop("\(arguments[3]) could not be pressed: \(result.rawValue)", status: 1) }
case "value":
    guard let value = text(kAXValueAttribute, of: found) else { stop("\(arguments[3]) has no value", status: 1) }
    print(value)
case "frame":
    var frame = CGRect.zero
    guard let value = attribute("AXFrame", of: found), AXValueGetValue(value as! AXValue, .cgRect, &frame) else {
        stop("\(arguments[3]) has no frame", status: 1)
    }
    print(Int(frame.minX), Int(frame.minY), Int(frame.width), Int(frame.height))
default: stop(usage, status: 64)
}
