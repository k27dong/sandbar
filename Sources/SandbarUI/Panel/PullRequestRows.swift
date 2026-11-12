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
                let startsTheList = index == 0 && list.reviewRequests.isEmpty
                let touchesAStack = isStack[index] || index > 0 && isStack[index - 1]
                Group {
                    switch entry {
                    case .single(let pullRequest): PullRequestRow(pullRequest: pullRequest, columns: columns)
                    case .stack(let stack): StackRows(stack: stack, columns: columns)
                    }
                }
                .padding(.top, touchesAStack && !startsTheList ? 3 : 0)
                .padding(.bottom, isStack[index] && index == isStack.count - 1 ? 3 : 0)
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
        let topFirst = model.preferences.stackOrder == .topFirst
        let isOpen = model.openStacks.contains(stack.id)
        let folds = stack.pullRequests.count > 3
        let shown = stack.shown(isOpen: isOpen)
        let rows: [PullRequest] = topFirst ? shown.reversed() : shown
        let fold = Button {
            model.openStacks.formSymmetricDifference([stack.id])
        } label: {
            HStack(spacing: 8) {
                Icon.stack.image.frame(width: 18)
                if isOpen {
                    Icon.fewer.image
                } else {
                    Text("+\(stack.pullRequests.count - shown.count)")
                        .font(Font(PullRequestRows.smallFont as CTFont))
                }
            }
            .foregroundStyle(foldHovered ? Color.primary : .secondary)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .overlay(alignment: topFirst ? .bottomLeading : .topLeading) { StackLine().frame(height: 3) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { foldHovered = $0 }

        VStack(alignment: .leading, spacing: 0) {
            if folds && topFirst { fold }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, pullRequest in
                PullRequestRow(
                    pullRequest: pullRequest, joinedAbove: index > 0 || folds && topFirst,
                    joinedBelow: index < rows.count - 1 || folds && !topFirst, columns: columns)
            }
            if folds && !topFirst { fold }
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
        let state: Icon =
            switch pullRequest.state {
            case .merging: .merging
            case .draft: .draft
            case .changesRequested: .changesRequested
            case .approved: .approved
            case .open: .open
            }
        let checks: Icon? =
            switch pullRequest.checks.verdict {
            case .passed: .checkPassed
            case .running: .checkRunning
            case .failed: .checkFailed
            case nil: nil
            }
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
                                .background(isHovered ? Color.white.opacity(0.32) : .facePlaceholder)
                        }
                        .frame(width: 16, height: 16)
                        .clipShape(.circle)
                    } else {
                        state.image.foregroundStyle(isHovered ? Color.white : state.tint ?? .primary)
                    }
                }
                .frame(width: 18)
                .padding(.top, twoLines ? 1 : 0)

                Text(pullRequest.title.replacing(#/\s+/#, with: " "))
                    .lineLimit(twoLines ? 2 : 1)
                    .lineSpacing(twoLines ? 1 : 0)
                    .padding(.vertical, twoLines ? 0.5 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    if let checks { checks.image.foregroundStyle(isHovered ? Color.white : checks.tint ?? .primary) }
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
                .foregroundStyle(isHovered ? Color.white.opacity(0.85) : .secondary)
                .frame(height: twoLines ? 15 : nil)
                .padding(.top, twoLines ? 2 : 0)
                .offset(y: twoLines ? 0 : 1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, twoLines ? 5 : 0)
            .frame(height: twoLines ? nil : 26)
            .foregroundStyle(isHovered ? Color.white : .primary)
            .background(isHovered ? Color.accentColor : .clear, in: .rect(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                if joinedAbove { StackLine(isHovered: isHovered).frame(height: 4) }
                if joinedBelow { StackLine(isHovered: isHovered).padding(.top, 22) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(pullRequest.title)
    }
}

private struct StackLine: View {
    var isHovered = false

    var body: some View {
        Rectangle()
            .fill(isHovered ? Color.white.opacity(0.6) : Color(nsColor: .tertiaryLabelColor))
            .frame(width: 2)  // the design's 1.5 points at 18.25 fall between pixels; browsers draw these 2 at 18
            .offset(x: 18)
    }
}

extension PullRequest {
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
