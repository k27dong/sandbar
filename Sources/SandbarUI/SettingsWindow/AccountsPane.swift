import SandbarCore
import SwiftUI

struct AccountsPane: View {
    @Environment(AppModel.self) private var model
    @State private var showsRepositories = false

    var body: some View {
        Form {
            Section("GitHub") {
                GitHubAccount()
                Picker(
                    "Pull requests from",
                    selection: Binding(
                        get: { model.choosesRepositories },
                        set: { chosen in
                            model.choosesRepositories = chosen
                            showsRepositories = chosen
                        })
                ) {
                    Text("All repositories").tag(false)
                    Text("Chosen repositories…").tag(true)
                }
                .disabled(model.needsGitHubSignIn)
            }
            ForEach(Tool.allCases, id: \.self) { tool in
                Section {
                    ToolAccounts(tool: tool)
                } header: {
                    Text(tool.title)
                } footer: {
                    if tool == Tool.allCases.last, let note = model.accountsNote {
                        FooterLine(text: note)
                    }
                }
            }
        }
        .sheet(isPresented: $showsRepositories) { RepositoryChoice() }
        .onAppear { model.findSignIns() }
    }
}

private struct GitHubAccount: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if case .code(let code) = model.gitHub {
            AccountRow(icon: .gitHub, detail: code.shownAddress) {
                Text(code.userCode).monospacedDigit()
            } trailing: {
                Button(SignInWords.copyCode) { model.copyCodeAndOpenGitHub(code) }
                Button(SignInWords.cancel) { model.cancelGitHubSignIn() }
            }
        } else if !model.needsGitHubSignIn, case .connected(let login, _) = model.gitHub {
            AccountRow(icon: .gitHub, detail: model.gitHubNote ?? model.hiddenOrganizationsNote ?? "github.com") {
                Text(login)
            } trailing: {
                Button("Sign Out") { model.signOutOfGitHub() }
                    .disabled(model.accountsAreLocked)
            }
        } else {
            AccountRow(icon: .gitHub, detail: model.gitHubFailure) {
                Text(SignInWords.notSignedIn)
            } trailing: {
                Button(model.gitHubSignInTitle) { Task { await model.signInToGitHub() } }
                    .disabled(model.accountsAreLocked)
            }
        }
    }
}

private struct ToolAccounts: View {
    @Environment(AppModel.self) private var model
    let tool: Tool

    var body: some View {
        let icon: Icon = tool == .claude ? .claude : .codex
        ForEach(model.accounts.filter { $0.tool == tool }) { account in
            NamedAccount(account: account, icon: icon)
        }
        if model.canUseExisting(tool) {
            AccountRow {
                Text(SignInWords.signedInOnThisMac)
            } trailing: {
                Button(SignInWords.useIt) { Task { await model.useExisting(tool) } }
                    .disabled(model.accountsAreLocked)
            }
        }
        switch model.signInStep[tool] ?? .idle {
        case .fetching, .waitingForBrowser:
            let isWaiting = model.signInStep[tool] == .waitingForBrowser
            AccountRow(
                icon: icon, detail: isWaiting ? SignInWords.finishInBrowser : SignInWords.fetching(tool),
                onDetailClick: isWaiting ? model.openSignInAgain : nil
            ) {
                Text(tool.title)
            } trailing: {
                ProgressView().controlSize(.small)
                Button(SignInWords.cancel) { model.cancelSignIn(tool) }
            }
            if isWaiting, tool == .claude { PastedCode() }
        case .idle, .failed:
            AccountRow {
                Text(model.signInTrouble(tool) ?? "").foregroundStyle(.secondary)
            } trailing: {
                Button("Add Account…") { Task { await model.addAccount(tool) } }
                    .disabled(model.accountsAreLocked)
            }
        }
    }
}

private struct NamedAccount: View {
    @Environment(AppModel.self) private var model
    @Environment(\.controlActiveState) private var windowState
    private let account: Account
    private let icon: Icon
    @State private var name: String
    @State private var isPointedAt = false
    @FocusState private var isEditing: Bool

    init(account: Account, icon: Icon) {
        self.account = account
        self.icon = icon
        _name = State(initialValue: account.name)  // set in a later turn, the first drawing would have no name
    }

    var body: some View {
        let reading = model.snapshot.accounts.first { $0.id == account.id }?.limits
        let field = RoundedRectangle(cornerRadius: 5).inset(by: -3)
        AccountRow(icon: icon, detail: reading?.trouble == nil ? nil : reading?.detail) {
            HStack(spacing: 0) {
                if model.canRenameAccounts {
                    Text(name.isEmpty ? " " : name)
                        .hidden()  // sizes the field to the name, so that the plan stays right after it
                        .overlay {
                            TextField("", text: $name)
                                .labelsHidden()  // a form gives a field a line for its label, which pushes it down
                                .textFieldStyle(.plain)
                                .focused($isEditing)
                                .onSubmit { isEditing = false }
                                .onExitCommand {
                                    name = account.name
                                    isEditing = false
                                }
                                .accessibilityLabel("Name")
                        }
                        .background { field.fill(.quaternary).opacity(isPointedAt || isEditing ? 1 : 0) }
                        .overlay {
                            field.strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                                .opacity(isEditing ? 1 : 0)
                        }
                        .onHover { isPointedAt = $0 }
                        .padding(.trailing, isEditing ? 4 : 0)
                } else {
                    Text(account.name)
                }
                if !account.plan.isEmpty { Text(" (\(account.plan))") }
            }
        } trailing: {
            Button("Remove") { Task { await model.remove(account) } }
                .disabled(model.accountsAreLocked)
        }
        .onChange(of: account.name) { name = account.name }
        .onChange(of: isEditing) {
            guard !isEditing else { return }
            if name != account.name { model.rename(account, to: name) }
            name = model.accounts.first { $0.id == account.id }?.name ?? account.name
        }
        .onChange(of: windowState) {
            if windowState == .inactive { isEditing = false }  // closing the window keeps what was typed
        }
    }
}

private struct PastedCode: View {
    @Environment(AppModel.self) private var model
    @State private var code = ""

    var body: some View {
        TextField("", text: $code, prompt: Text(SignInWords.pasteCode))
            .labelsHidden()
            .onSubmit {
                model.pasteCode(code)
                code = ""
            }
    }
}

private struct AccountRow<Title: View, Trailing: View>: View {
    var icon: Icon?
    var detail: String?
    var onDetailClick: (@MainActor () -> Void)?
    @ViewBuilder let title: Title
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            if let icon { icon.image.foregroundStyle(icon.tint ?? .primary).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 1) {
                title
                if let detail {
                    let line = Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    if let onDetailClick { Button(action: onDetailClick) { line }.buttonStyle(.plain) } else { line }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
    }
}

package struct RepositoryChoice: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    package init() {}

    package var body: some View {
        let chosen = model.preferences.chosenRepositories ?? []
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.repositoryChoices, id: \.self) { repository in
                Toggle(
                    repository,
                    isOn: Binding(get: { chosen.contains(repository) }, set: { model.choose(repository, $0) }))
            }
            .toggleStyle(.checkbox)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 320)
    }
}
