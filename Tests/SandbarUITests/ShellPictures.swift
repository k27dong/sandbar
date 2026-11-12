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
        let sheet = HStack(spacing: 12) {
            ForEach(Icon.allCases, id: \.self) { icon in
                icon.image.foregroundStyle(icon.tint ?? .primary)
            }
        }
        .padding(12)
        for dark in [false, true] {
            _ = try Pictures.draw(sheet, named: "icons", dark: dark)
        }
        for icon in Icon.allCases {
            let size = NSHostingView(rootView: icon.image).fittingSize
            #expect(size.width > 0 && size.height > 0, "\(icon)")
        }
    }
}
