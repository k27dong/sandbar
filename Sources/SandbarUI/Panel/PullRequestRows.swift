import AppKit
import SandbarCore
import SwiftUI

struct PullRequestRows: View {
    struct Columns {
        var number: CGFloat
        var time: CGFloat
    }

    static let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    @Environment(AppModel.self) private var model

    var body: some View {
        let list = model.list
        let preferences = model.preferences
        let shown =
            list.reviewRequests
            + list.mine.flatMap { entry in
                switch entry {
                case .single(let pullRequest): [pullRequest]
                case .stack(let stack): stack.shown(isOpen: model.openStacks.contains(stack.id))
                }
            }
        let columns = Columns(
            number: min(136, Self.width(of: shown.map { $0.numberText(withRepository: preferences.showsRepository) })),
            time: Self.width(of: shown.compactMap { $0.timeText(preferences.time, now: model.now) }))
        let isStack = list.mine.map { if case .stack = $0 { true } else { false } }

        ScrollViewReader { scroll in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(list.reviewRequests) { pullRequest in
                    PullRequestRow(pullRequest: pullRequest, isReviewRequest: true, columns: columns)
                }
                if !list.reviewRequests.isEmpty { ThinLine() }
                if list.mine.isEmpty {
                    Text("No open pull requests")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                        .padding(.horizontal, 10)
                }
                ForEach(Array(list.mine.enumerated()), id: \.element.id) { index, entry in
                    let besideAStack = index > 0 && (isStack[index] || isStack[index - 1])
                    Group {
                        switch entry {
                        case .single(let pullRequest): PullRequestRow(pullRequest: pullRequest, columns: columns)
                        case .stack(let stack): StackRows(stack: stack, columns: columns)
                        }
                    }
                    .padding(.top, besideAStack ? 3 : 0)
                    .padding(.bottom, isStack[index] && index == isStack.count - 1 ? 3 : 0)
                }
            }
            .onChange(of: model.selection) {
                if let selection = model.selection { scroll.scrollTo(selection) }
            }
        }
    }

    private static func width(of texts: [String]) -> CGFloat {
        texts.map { ceil(NSAttributedString(string: $0, attributes: [.font: smallFont]).size().width) }.max() ?? 0
    }
}

private struct StackRows: View {
    @Environment(AppModel.self) private var model
    @State private var foldHovered = false
    let stack: Stack
    let columns: PullRequestRows.Columns

    var body: some View {
        let isOpen = model.openStacks.contains(stack.id)
        let rows = model.rows(of: stack)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.selection) { index, row in
                switch row {
                case .pullRequest(let pullRequest):
                    PullRequestRow(
                        pullRequest: pullRequest, joinedAbove: index > 0, joinedBelow: index < rows.count - 1,
                        columns: columns)
                case .fold:
                    let isHighlighted = foldHovered || model.selection == row.selection
                    Button {
                        model.openStacks.formSymmetricDifference([stack.id])
                    } label: {
                        HStack(spacing: 8) {
                            Icon.stack.image.frame(width: 18)
                            if isOpen {
                                Icon.fewer.image
                            } else {
                                Text("+\(stack.foldedAway)")
                                    .font(Font(PullRequestRows.smallFont as CTFont))
                            }
                        }
                        .foregroundStyle(isHighlighted ? Color.primary : .secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .overlay(alignment: index == 0 ? .bottomLeading : .topLeading) { StackLine().frame(height: 3) }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .onHover { foldHovered = $0 }
                    .accessibilityLabel(spoken(foldRowOf: stack, isOpen: isOpen))
                    .accessibilityAddTraits(model.selection == row.selection ? .isSelected : [])
                    .id(row.selection)
                }
            }
        }
    }
}

private struct PullRequestRow: View {
    @Environment(AppModel.self) private var model
    @State private var isHovered = false
    let pullRequest: PullRequest
    var isReviewRequest = false
    var joinedAbove = false
    var joinedBelow = false
    let columns: PullRequestRows.Columns

    var body: some View {
        let preferences = model.preferences
        let twoLines = preferences.titles == .twoLines
        let state = pullRequest.stateIcon
        let selection = AppModel.Selection.pullRequest(pullRequest.id)
        let isSelected = model.selection == selection
        let isHighlighted = isHovered || isSelected
        Button {
            model.open(pullRequest)
        } label: {
            HStack(alignment: twoLines ? .top : .center, spacing: 8) {
                ZStack {
                    if isReviewRequest {
                        AsyncImage(url: pullRequest.author.picture) { picture in
                            picture.resizable()
                        } placeholder: {
                            Text(pullRequest.author.login.prefix(2).uppercased())
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 16, height: 16)
                                .background(isHighlighted ? Color.white.opacity(0.32) : .facePlaceholder)
                        }
                        .frame(width: 16, height: 16)
                        .clipShape(.circle)
                    } else {
                        state.image.foregroundStyle(isHighlighted ? Color.white : state.tint ?? .primary)
                    }
                }
                .frame(width: 18)
                .padding(.top, twoLines ? 1 : 0)

                Text(pullRequest.oneLineTitle)
                    .lineLimit(twoLines ? 2 : 1)
                    .lineSpacing(twoLines ? 1 : 0)
                    .padding(.vertical, twoLines ? 0.5 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    if let checks = pullRequest.checksIcon {
                        checks.image.foregroundStyle(isHighlighted ? Color.white : checks.tint ?? .primary)
                    }
                }
                .frame(width: 14)
                .padding(.top, twoLines ? 3 : 0)

                Group {
                    Text(pullRequest.numberText(withRepository: preferences.showsRepository))
                        .frame(width: columns.number, alignment: .trailing)
                    if let time = pullRequest.timeText(preferences.time, now: model.now) {
                        Text(time).frame(width: columns.time, alignment: .trailing)
                    }
                }
                .font(Font(PullRequestRows.smallFont as CTFont))
                .lineLimit(1)
                .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : .secondary)
                .frame(height: twoLines ? 15 : nil)
                .padding(.top, twoLines ? 2 : 0)
                .offset(y: twoLines ? 0 : 1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, twoLines ? 5 : 0)
            .frame(height: twoLines ? nil : 26)
            .foregroundStyle(isHighlighted ? Color.white : .primary)
            .background(isHighlighted ? Color.accentColor : .clear, in: .rect(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                if joinedAbove { StackLine(isHighlighted: isHighlighted).frame(height: 4) }
            }
            .overlay(alignment: .topLeading) {
                if joinedBelow { StackLine(isHighlighted: isHighlighted).padding(.top, 22) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(pullRequest.title)
        .accessibilityLabel(
            isReviewRequest
                ? spoken(reviewRequest: pullRequest, now: model.now, time: preferences.time)
                : spoken(pullRequest, now: model.now, time: preferences.time)
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .id(selection)
    }
}

private struct StackLine: View {
    var isHighlighted = false

    var body: some View {
        Rectangle()
            .fill(isHighlighted ? Color.white.opacity(0.6) : Color(nsColor: .tertiaryLabelColor))
            .frame(width: 1.5)
            .offset(x: 18.25)
    }
}

package func spoken(_ pullRequest: PullRequest, now: Date, time: Preferences.TimeShown) -> String {
    sentence(startingWith: pullRequest.stateIcon.spoken, pullRequest, now: now, time: time)
}

/// A review request says who asked, where its row shows that person's face in place of the state.
package func spoken(reviewRequest: PullRequest, now: Date, time: Preferences.TimeShown) -> String {
    sentence(startingWith: "Review requested by \(reviewRequest.author.login)", reviewRequest, now: now, time: time)
}

package func spoken(foldRowOf stack: Stack, isOpen: Bool) -> String {
    isOpen ? Icon.fewer.spoken : "\(stack.foldedAway) more in this stack"
}

private func sentence(
    startingWith opening: String, _ pullRequest: PullRequest, now: Date, time: Preferences.TimeShown
) -> String {
    [
        opening, pullRequest.oneLineTitle, pullRequest.checksIcon?.spoken.lowercased(), "number \(pullRequest.number)",
        pullRequest.timeText(time, now: now).map(ShortTime.spoken),
    ]
    .compactMap(\.self).joined(separator: ", ")
}

extension Stack {
    fileprivate var foldedAway: Int { pullRequests.count - shown(isOpen: false).count }
}

extension PullRequest {
    fileprivate var oneLineTitle: String { title.replacing(#/\s+/#, with: " ") }

    fileprivate var stateIcon: Icon {
        switch state {
        case .merging: .merging
        case .draft: .draft
        case .changesRequested: .changesRequested
        case .approved: .approved
        case .open: .open
        }
    }

    fileprivate var checksIcon: Icon? {
        switch checks.verdict {
        case .passed: .checkPassed
        case .running: .checkRunning
        case .failed: .checkFailed
        case nil: nil
        }
    }

    fileprivate func numberText(withRepository: Bool) -> String {
        withRepository ? "\(repositoryName) #\(number)" : "#\(number)"
    }

    fileprivate func timeText(_ shown: Preferences.TimeShown, now: Date) -> String? {
        switch shown {
        case .sinceOpened: ShortTime.age(since: createdAt, to: now)
        case .sinceUpdate: ShortTime.age(since: updatedAt, to: now)
        case .off: nil
        }
    }
}
