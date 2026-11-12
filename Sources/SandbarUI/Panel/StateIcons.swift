import AppKit
import SwiftUI

package enum Icon: String, CaseIterable {
    case open = """
        <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="#000" \
        stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="4" cy="3.6" r="1.8"/>\
        <circle cx="4" cy="12.4" r="1.8"/><circle cx="12" cy="12.4" r="1.8"/>\
        <path d="M4 5.4v5.2M7.2 3.6h2.8a2 2 0 0 1 2 2v5"/></svg>
        """
    case draft = """
        <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="#000" \
        stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="4" cy="3.6" r="1.8"/>\
        <circle cx="4" cy="12.4" r="1.8"/><circle cx="12" cy="12.4" r="1.8"/><path d="M4 5.4v5.2"/>\
        <path d="M12 10.3V9.2M12 7.3V6.2M12 4.3V3.2"/></svg>
        """
    case merging = """
        <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="#000" \
        stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="4" cy="3.6" r="1.8"/>\
        <circle cx="4" cy="12.4" r="1.8"/><circle cx="12" cy="8.6" r="1.8"/>\
        <path d="M4 5.4v5.2M4 5.6c0 2.4 2 3 6.2 3"/></svg>
        """
    case approved = """
        <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 16 16">\
        <path fill-rule="evenodd" d="M1 8a7 7 0 1 0 14 0a7 7 0 1 0-14 0ZM4.299 8.901L6.399 11.001A0.85 0.85 0 0 0 \
        7.628 10.972L11.728 6.472A0.85 0.85 0 0 0 11.672 5.272A0.85 0.85 0 0 0 10.472 5.328L6.971 9.169L5.501 \
        7.699A0.85 0.85 0 0 0 4.299 7.699A0.85 0.85 0 0 0 4.299 8.901Z"/></svg>
        """
    case changesRequested = """
        <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 16 16">\
        <path fill-rule="evenodd" d="M1 8a7 7 0 1 0 14 0a7 7 0 1 0-14 0ZM7.2 3.6a0.8 0.8 0 0 1 1.6 0v1.7h1.7a0.8 0.8 0 \
        0 1 0 1.6H8.8v1.7a0.8 0.8 0 0 1-1.6 0V6.9H5.5a0.8 0.8 0 0 1 0-1.6h1.7ZM5.5 10.7h5a0.8 0.8 0 0 1 0 1.6h-5a0.8 \
        0.8 0 0 1 0-1.6Z"/></svg>
        """
    case checkPassed = """
        <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 12 12">\
        <path d="M2.2 6.4l2.4 2.4L9.8 3.4" fill="none" stroke="#000" stroke-width="1.8" stroke-linecap="round" \
        stroke-linejoin="round"/></svg>
        """
    case checkRunning = """
        <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 12 12">\
        <circle cx="6" cy="6" r="3" fill="#000"/></svg>
        """
    case checkFailed = """
        <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 12 12">\
        <path d="M3 3l6 6M9 3L3 9" fill="none" stroke="#000" stroke-width="1.8" stroke-linecap="round"/></svg>
        """
    case stack = """
        <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 16 16">\
        <path fill="#000" d="M7.122.392a1.75 1.75 0 0 1 1.756 0l5.003 2.902c.83.481.83 1.68 0 2.162L8.878 8.358a1.75 \
        1.75 0 0 1-1.756 0L2.119 5.456a1.251 1.251 0 0 1 0-2.162ZM8.125 1.69a.248.248 0 0 0-.25 0l-4.63 2.685 4.63 \
        2.685a.248.248 0 0 0 .25 0l4.63-2.685ZM1.601 7.789a.75.75 0 0 1 1.025-.273l5.249 3.044a.248.248 0 0 0 .25 \
        0l5.249-3.044a.75.75 0 0 1 .752 1.298l-5.248 3.044a1.75 1.75 0 0 1-1.756 0L1.874 8.814A.75.75 0 0 1 1.6 \
        7.789Zm0 3.5a.75.75 0 0 1 1.025-.273l5.249 3.044a.248.248 0 0 0 .25 0l5.249-3.044a.75.75 0 0 1 .752 \
        1.298l-5.248 3.044a1.75 1.75 0 0 1-1.756 0l-5.248-3.044a.75.75 0 0 1-.273-1.025Z"/></svg>
        """
    case fewer = """
        <svg xmlns="http://www.w3.org/2000/svg" width="9" height="6" viewBox="0 0 9 6">\
        <path d="M1 5l3.5-3.5L8 5" fill="none" stroke="#000" stroke-width="1.5" stroke-linecap="round" \
        stroke-linejoin="round"/></svg>
        """
    case refresh = """
        <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 13 13">\
        <path d="M11 6.5A4.5 4.5 0 1 1 9.4 3" fill="none" stroke="#000" stroke-width="1.3" stroke-linecap="round"/>\
        <path d="M9.9 1v2.6H7.3" fill="none" stroke="#000" stroke-width="1.3" stroke-linecap="round" \
        stroke-linejoin="round"/></svg>
        """
    case gear = """
        <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 13 13">\
        <circle cx="6.5" cy="6.5" r="2" fill="none" stroke="#000" stroke-width="1.3"/>\
        <path d="M6.5 1v1.6M6.5 10.4V12M1 6.5h1.6M10.4 6.5H12M2.6 2.6l1.1 1.1M9.3 9.3l1.1 1.1M2.6 10.4l1.1-1.1M9.3 \
        3.7l1.1-1.1" stroke="#000" stroke-width="1.3" stroke-linecap="round"/></svg>
        """
    case gitHub = """
        <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="#000" \
        stroke-width="1.6" stroke-linecap="round"><circle cx="4.2" cy="3.6" r="1.9"/>\
        <circle cx="4.2" cy="12.4" r="1.9"/><circle cx="11.8" cy="12.4" r="1.9"/>\
        <path d="M4.2 5.5v5M7 3.6h2.8a2 2 0 0 1 2 2v4.9"/></svg>
        """
    case claude = """
        <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 14 14">\
        <g stroke="#000" stroke-width="1.9" stroke-linecap="round">\
        <line x1="7" y1="1.4" x2="7" y2="12.6" transform="rotate(0 7 7)"/>\
        <line x1="7" y1="1.4" x2="7" y2="12.6" transform="rotate(45 7 7)"/>\
        <line x1="7" y1="1.4" x2="7" y2="12.6" transform="rotate(90 7 7)"/>\
        <line x1="7" y1="1.4" x2="7" y2="12.6" transform="rotate(135 7 7)"/></g></svg>
        """
    case codex = """
        <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 14 14">\
        <g fill="none" stroke="#000" stroke-width="1.3"><ellipse cx="7" cy="7" rx="5.6" ry="2.6" transform="rotate(0 7 \
        7)"/><ellipse cx="7" cy="7" rx="5.6" ry="2.6" transform="rotate(60 7 7)"/>\
        <ellipse cx="7" cy="7" rx="5.6" ry="2.6" transform="rotate(120 7 7)"/></g></svg>
        """

    package var image: Image { Self.images[self]! }

    private static let images: [Icon: Image] = Dictionary(
        uniqueKeysWithValues: allCases.map { icon in
            let template =
                NSImage(data: Data(icon.rawValue.utf8))
                ?? NSImage(size: .zero)  // a bad SVG gets no size, which a test reports by name; a crash hides the rest
            template.isTemplate = true
            return (icon, Image(nsImage: template))
        })

    package var tint: Color? {
        switch self {
        case .open, .approved: .gitHubOpen
        case .draft: .gitHubDraft
        case .merging: .gitHubQueue
        case .changesRequested, .checkFailed: .gitHubFail
        case .checkPassed: .gitHubPass
        case .checkRunning: .gitHubRun
        case .claude: .claudeMark
        case .codex: .codexMark
        case .stack, .fewer, .refresh, .gear, .gitHub: nil
        }
    }
}

extension Color {
    package static let gitHubOpen = Color(light: 0x1A7F37, dark: 0x3FB950)
    package static let gitHubDraft = Color(light: 0x59636E, dark: 0x9198A1)
    package static let gitHubQueue = Color(light: 0x9A6700, dark: 0xD29922)
    package static let gitHubPass = Color(light: 0x1A7F37, dark: 0x3FB950)
    package static let gitHubFail = Color(light: 0xD1242F, dark: 0xF85149)
    package static let gitHubRun = Color(light: 0xBF8700, dark: 0xD29922)
    package static let usageWarning = Color(light: 0xF08A00, dark: 0xFF9F0A)
    package static let usageCritical = Color(light: 0xFF3B30, dark: 0xFF453A)
    package static let warningText = Color(light: 0xA85200, dark: 0xFFB54A)
    package static let facePlaceholder = Color(light: 0x8E8E93, dark: 0x7C7C82)
    package static let claudeMark = Color(light: 0xD97757, dark: 0xE08A6C)
    package static let codexMark = Color(light: 0x1B1B1D, dark: 0xF2F2F2)

    private init(light: Int, dark: Int) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            })
    }
}
