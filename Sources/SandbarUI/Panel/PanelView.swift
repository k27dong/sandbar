import AppKit
import SandbarCore
import SwiftUI

package struct PanelView: View {
    @Environment(AppModel.self) private var model
    @State private var refreshHovered = false
    @State private var gearHovered = false
    private let maxHeight: CGFloat

    package init(maxHeight: CGFloat = .infinity) {
        self.maxHeight = maxHeight
    }

    package var body: some View {
        let tone = model.isOffline ? Color.warningText : .secondary
        VStack(spacing: 0) {
            ScrollView {
                PullRequestRows()
            }
            .scrollIndicators(.never)  // a bar that takes room would move the rows out of line with the footer
            ThinLine()
            HStack(spacing: 8) {
                Button {
                    Task { await model.refresh(.all) }
                } label: {
                    HStack(spacing: 5) {
                        Icon.refresh.image
                        Text(model.status)
                    }
                    .foregroundStyle(tone)
                    .padding(.horizontal, 4)
                    .frame(height: 19)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .background(.quinary.opacity(refreshHovered ? 1 : 0), in: .rect(cornerRadius: 6))
                .onHover { refreshHovered = $0 }
                .help(model.snapshot.pullRequests.detail ?? "")
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
                .foregroundStyle(tone)
                .background(.quinary.opacity(gearHovered ? 1 : 0), in: .rect(cornerRadius: 6))
                .onHover { gearHovered = $0 }
            }
            .font(.system(size: 11))
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 4, trailing: 10))
        }
        .font(.system(size: 13))
        .padding(6)
        .frame(width: 440)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ThinLine: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }
}
