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
                    if tool == Tool.allCases.last, let note = model.accountsNote { Text(note) }
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
                    .disabled(model.isChangingAccounts)
            }
        } else {
            AccountRow(icon: .gitHub, detail: model.gitHubFailure) {
                Text(SignInWords.notSignedIn)
            } trailing: {
                Button(model.gitHubSignInTitle) { Task { await model.signInToGitHub() } }
                    .disabled(model.isChangingAccounts)
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
                    .disabled(model.isChangingAccounts)
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
            let failure = if case .failed(let sentence) = model.signInStep[tool] { sentence } else { "" }
            AccountRow {
                Text(failure).foregroundStyle(.secondary)
            } trailing: {
                Button("Add Account…") { Task { await model.addAccount(tool) } }
                    .disabled(model.isChangingAccounts)
            }
        }
    }
}

private struct NamedAccount: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let icon: Icon
    @State private var draft: String?
    @FocusState private var isEditing: Bool

    var body: some View {
        let reading = model.snapshot.accounts.first { $0.id == account.id }?.limits
        AccountRow(icon: icon, detail: reading?.trouble == nil ? nil : reading?.detail) {
            HStack(spacing: 0) {
                if let draft {
                    Text(draft).hidden()  // sizes the field to the name, so that the plan stays right after it
                        .overlay {
                            TextField("", text: Binding(get: { draft }, set: { self.draft = $0 }))
                                .textFieldStyle(.plain)
                                .focused($isEditing)
                                .onSubmit { commit() }
                                .onAppear { isEditing = true }
                                .onExitCommand { self.draft = nil }
                        }
                        .padding(.trailing, 4)
                } else {
                    Text(account.name)
                        .onTapGesture { draft = account.name }
                }
                if !account.plan.isEmpty { Text(" (\(account.plan))") }
            }
        } trailing: {
            Button("Remove") { Task { await model.remove(account) } }
                .disabled(model.isChangingAccounts)
        }
        .onChange(of: isEditing) {
            if !isEditing { commit() }
        }
    }

    private func commit() {
        guard let draft else { return }
        model.rename(account, to: draft)
        self.draft = nil
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
            if let icon { icon.image.foregroundStyle(icon.tint ?? .primary) }
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
