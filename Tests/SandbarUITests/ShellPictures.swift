import AppKit
import SandbarCore
import SandbarUI
import SwiftUI
import Testing

@Suite(.serialized) struct ShellPictures {
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

    @Test func menuBarItemDraws() throws {
        let states: [(ring: StatusItem.Ring, count: Int?, dimmed: Bool, colored: Bool)] = [
            (.none, nil, false, false), (.used(0.41, .normal), 12, false, false), (.used(0.91, .near), 12, false, true),
            (.used(1, .full), 12, false, true), (.used(0.41, .normal), 12, true, false),
        ]
        let item = StatusItem {}
        for dark in [false, true] {
            let pictures = try states.map { state in
                item.show(ring: state.ring, count: state.count, dimmed: state.dimmed)
                let picture = try #require(item.button?.image)
                #expect(picture.isTemplate != state.colored, "\(state.ring)")
                return picture
            }
            #expect(pictures[0].size == NSSize(width: 18, height: 18))
            let sheet = HStack(spacing: 12) {
                ForEach(pictures, id: \.self) { picture in
                    Image(nsImage: picture)
                        .foregroundStyle(Color(nsColor: .textColor))  // a template gets the menu bar's full ink
                }
            }
            .padding(12)
            _ = try Pictures.draw(sheet, named: "menuBarItem", dark: dark)
        }
    }
}
