import AppKit
import SandbarCore
import SwiftUI

package struct SetupView: View {
    @Environment(AppModel.self) private var model

    package init() {}

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .code(let code) = model.gitHub {
                Heading(title: "Connect GitHub", subtitle: "Enter this code on the GitHub page that just opened.")
                VStack(spacing: 0) {
                    Text(code.shownAddress)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(height: 18)
                    Text(code.userCode)
                        .font(.system(size: 24, weight: .semibold).monospacedDigit())
                        .tracking(1.92)
                        .frame(height: 32)
                        .padding(.top, 4)
                        .padding(.bottom, 10)
                    Button(SignInWords.copyCode) { model.copyCodeAndOpenGitHub(code) }
                        .buttonStyle(RowButton(isPrimary: true))
                }
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(.quinary, in: .rect(cornerRadius: 12))
                .padding(EdgeInsets(top: 8, leading: 10, bottom: 4, trailing: 10))
                HStack(spacing: 8) {
                    if model.isWaitingForGitHub {
                        Spinner()
                        Text("Waiting for GitHub to confirm")
                    }
                    Button("Back") { model.cancelGitHubSignIn() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.linkText)
                        .padding(.horizontal, 2)
                        .frame(maxWidth: .infinity, alignment: model.isWaitingForGitHub ? .trailing : .leading)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 36)
            } else {
                let next = Tool.allCases.first { tool in !model.accounts.contains { $0.tool == tool } }
                Heading(title: "Connect your accounts", subtitle: "Sign-ins stay on this Mac.")
                GitHubRow(namesHiddenOrganizations: true)
                ForEach(Tool.allCases, id: \.self) { tool in
                    ToolRow(tool: tool, isNext: !model.needsGitHubSignIn && tool == next)
                }
                if !model.needsGitHubSignIn {
                    Button("Done") { model.finishSetup() }
                        .buttonStyle(RowButton(isPrimary: next == nil))
                        .unavailable(model.isSigningIn)  // Done would leave a sign-in with no Cancel and no code field
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(EdgeInsets(top: 4, leading: 10, bottom: 6, trailing: 10))
                }
            }
        }
    }
}

enum SignInWords {
    static let notSignedIn = "Not signed in"
    static let signedInOnThisMac = "Signed in on this Mac"
    static let useIt = "Use it"
    static let useGh = "Use gh's sign-in"
    static let copyCode = "Copy code and open GitHub"
    static let cancel = "Cancel"
    static let finishInBrowser = "Finish in your browser"
    static let pasteCode = "Paste code here if prompted"

    static func fetching(_ tool: Tool) -> String { "Fetching \(tool.programName)…" }
}

extension AppModel {
    var gitHubSignInTitle: String { canUseGh ? SignInWords.useGh : "Connect" }
}

extension GitHubSignIn.Code {
    var shownAddress: String { "\(address.host() ?? "")\(address.path())" }
}

struct GitHubRow: View {
    @Environment(AppModel.self) private var model
    var namesHiddenOrganizations = false

    var body: some View {
        let needsSignIn = model.needsGitHubSignIn
        let connection: (login: String, throughGh: Bool)? =
            if case .connected(let login, let throughGh) = model.gitHub { (login, throughGh) } else { nil }
        let failure = model.gitHubFailure
        let hidden = namesHiddenOrganizations && !needsSignIn ? model.hiddenOrganizationsNote : nil
        let detail = failure ?? hidden ?? (needsSignIn ? nil : connection?.login) ?? "Your pull requests and reviews"
        ConnectionRow(icon: .gitHub, name: "GitHub", detail: detail, isFailure: failure != nil) {
            if needsSignIn {
                SignInButton(title: model.gitHubSignInTitle, isPrimary: true) { await model.signInToGitHub() }
            } else if hidden != nil, model.canUseGh, connection?.throughGh == false {
                SignInButton(title: SignInWords.useGh, isPrimary: false) { await model.useGhSignIn() }
            } else {
                ConnectedMark()
            }
        }
    }
}

private struct ToolRow: View {
    @Environment(AppModel.self) private var model
    let tool: Tool
    let isNext: Bool

    var body: some View {
        let icon: Icon = tool == .claude ? .claude : .codex
        let step = model.signInStep[tool] ?? .idle
        let cancel = HStack(spacing: 10) {
            Spinner()
            Button(SignInWords.cancel) { model.cancelSignIn(tool) }
                .buttonStyle(RowButton(isPrimary: false))
        }
        let signIn = SignInButton(title: model.canUseExisting(tool) ? SignInWords.useIt : "Sign in", isPrimary: isNext)
        {
            if model.canUseExisting(tool) { await model.useExisting(tool) } else { await model.addAccount(tool) }
        }
        if let account = model.accounts.first(where: { $0.tool == tool }) {
            ConnectionRow(icon: icon, name: tool.title, detail: account.plan.isEmpty ? account.name : account.plan) {
                ConnectedMark()
            }
        } else {
            switch step {
            case .fetching:
                ConnectionRow(icon: icon, name: tool.title, detail: SignInWords.fetching(tool)) { cancel }
            case .waitingForBrowser:
                ConnectionRow(
                    icon: icon, name: tool.title, detail: SignInWords.finishInBrowser,
                    onDetailClick: model.openSignInAgain
                ) { cancel }
                if tool == .claude { PastedCodeField() }
            case .failed(let sentence):
                ConnectionRow(icon: icon, name: tool.title, detail: sentence, isFailure: true) { signIn }
            case .idle:
                switch model.existingSignIns[tool] {
                case nil:
                    ConnectionRow(icon: icon, name: tool.title, detail: "Read limits from \(tool.programName)") {}
                case .unreadable(let sentence):
                    ConnectionRow(icon: icon, name: tool.title, detail: sentence, isFailure: true) { signIn }
                case .usable, .absent:
                    ConnectionRow(
                        icon: icon, name: tool.title,
                        detail: model.canUseExisting(tool) ? SignInWords.signedInOnThisMac : SignInWords.notSignedIn
                    ) { signIn }
                }
            }
        }
    }
}

private struct Heading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(height: 18)
                .padding(.top, 8)
                .padding(.bottom, 2)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(height: 15)
                .padding(.bottom, 6)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
    }
}

private struct ConnectionRow<Trailing: View>: View {
    let icon: Icon
    let name: String
    let detail: String
    var isFailure = false
    var onDetailClick: (@MainActor () -> Void)?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        let secondLine = Text(detail)
            .font(.system(size: 11))
            .foregroundStyle(isFailure ? Color.warningText : .secondary)
            .frame(height: 14.5)
        HStack(spacing: 10) {
            icon.image.foregroundStyle(icon.tint ?? .primary)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).frame(height: 17.5)
                if let onDetailClick {
                    Button(action: onDetailClick) { secondLine }.buttonStyle(.plain)
                } else {
                    secondLine.help(isFailure ? detail : "")
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
    }
}

private struct SignInButton: View {
    @Environment(AppModel.self) private var model
    let title: String
    let isPrimary: Bool
    let action: @MainActor () async -> Void

    var body: some View {
        Button(title) {
            Task { await action() }
        }
        .buttonStyle(RowButton(isPrimary: isPrimary))
        .unavailable(model.accountsAreLocked)
    }
}

extension View {
    fileprivate func unavailable(_ isUnavailable: Bool) -> some View {
        disabled(isUnavailable).opacity(isUnavailable ? 0.4 : 1)
    }
}

private struct RowButton: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isPrimary ? Color.white : .primary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(
                isPrimary ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: .rect(cornerRadius: 7)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct ConnectedMark: View {
    var body: some View {
        Circle()
            .fill(Color.connected)
            .frame(width: 12, height: 12)
            .overlay {
                Path { check in
                    check.move(to: CGPoint(x: 3.2, y: 6.2))
                    check.addLine(to: CGPoint(x: 5.1, y: 8.1))
                    check.addLine(to: CGPoint(x: 8.9, y: 4.1))
                }
                .stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            .frame(width: 14, height: 14)
    }
}

private struct Spinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { moment in
            let turn = moment.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            ZStack {
                Circle().inset(by: 0.8).trim(from: 0.25, to: 1).stroke(.tertiary, lineWidth: 1.6)
                Circle().inset(by: 0.8).trim(from: 0, to: 0.25).stroke(.secondary, lineWidth: 1.6)
            }
            .rotationEffect(.degrees(360 * turn - 135))
        }
        .frame(width: 15.2, height: 15.2)
    }
}

private struct PastedCodeField: View {
    @Environment(AppModel.self) private var model
    @State private var code = ""

    var body: some View {
        TextField(SignInWords.pasteCode, text: $code)
            .textFieldStyle(.plain)
            .font(.system(size: 11.5, design: .monospaced))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(.quinary, in: .rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 0.5) }
            .padding(EdgeInsets(top: 2, leading: 34, bottom: 8, trailing: 10))
            .onSubmit {
                model.pasteCode(code)
                code = ""
            }
    }
}
