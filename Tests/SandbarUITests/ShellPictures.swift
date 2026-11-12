import AppKit
import SandbarUI
import SwiftUI
import Testing

@Suite(.serialized) struct ShellPictures {
    @Test func emptyPanelDraws() throws {
        for dark in [false, true] {
            let file = try Pictures.draw(PanelView(), named: "emptyPanel", dark: dark)
            let data = try Data(contentsOf: file)
            let picture = try #require(NSBitmapImageRep(data: data))
            #expect(picture.pixelsWide == 880)
        }
    }

    @Test func everyIconDraws() throws {
        for dark in [false, true] {
            let sheet = HStack(spacing: 12) {
                ForEach(Icon.allCases, id: \.self) { icon in
                    icon.image.foregroundStyle(Self.color(of: icon, dark: dark))
                }
            }
            .padding(12)
            _ = try Pictures.draw(sheet, named: "icons", dark: dark)
        }
        for icon in Icon.allCases {
            let size = NSHostingView(rootView: icon.image).fittingSize
            #expect(size.width > 0 && size.height > 0, "\(icon)")
        }
    }

    private static func color(of icon: Icon, dark: Bool) -> Color {
        func rgb(_ hex: Int) -> Color {
            Color(
                red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255)
        }
        return switch icon {
        case .open, .approved, .checkPassed: rgb(dark ? 0x3FB950 : 0x1A7F37)
        case .draft: rgb(dark ? 0x9198A1 : 0x59636E)
        case .merging: rgb(dark ? 0xD29922 : 0x9A6700)
        case .changesRequested, .checkFailed: rgb(dark ? 0xF85149 : 0xD1242F)
        case .checkRunning: rgb(dark ? 0xD29922 : 0xBF8700)
        case .claude: rgb(dark ? 0xE08A6C : 0xD97757)
        case .codex: rgb(dark ? 0xF2F2F2 : 0x1B1B1D)
        case .gitHub: .primary
        case .stack, .refresh, .gear: .secondary
        }
    }
}
