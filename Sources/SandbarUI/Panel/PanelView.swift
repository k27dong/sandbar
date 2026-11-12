import AppKit
import SwiftUI

package struct PanelView: View {
    @State private var gearHovered = false

    package init() {}

    package var body: some View {
        VStack(spacing: 0) {
            Text("No open pull requests")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .padding(.horizontal, 10)
            Divider()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            HStack {
                Spacer()
                Menu {
                    Button("Quit Sandbar") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q")
                } label: {
                    Icon.gear.image
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .contentShape(.rect)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .foregroundStyle(.secondary)
                .background(.quinary.opacity(gearHovered ? 1 : 0), in: .rect(cornerRadius: 6))
                .onHover { gearHovered = $0 }
            }
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 4, trailing: 10))
        }
        .font(.system(size: 13))
        .padding(6)
        .frame(width: 440)
    }
}
