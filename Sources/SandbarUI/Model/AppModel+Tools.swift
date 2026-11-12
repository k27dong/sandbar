import AppKit
import SandbarCore

extension AppModel {

    func findTools() {
        let earlier = toolLookup
        toolLookup = Task { [weak self, findTool, download] in
            await earlier?.value  // an earlier lookup that ends late must not overwrite this one
            async let gh = findTool("gh")
            let found = await withTaskGroup(of: (Tool, URL?).self) { group in
                for tool in Tool.allCases { group.addTask { (tool, await findTool(tool.rawValue)) } }
                var found: [Tool: URL] = [:]
                for await (tool, program) in group { found[tool] = program }
                return found
            }
            var tools = found
            var fetchedTools: Set<Tool> = []
            var toolErrors: [Tool: any Error] = [:]
            for tool in Tool.allCases where found[tool] == nil {
                do {
                    guard let copy = try download.installed(tool) else { continue }
                    tools[tool] = copy
                    fetchedTools.insert(tool)
                } catch {
                    toolErrors[tool] = error
                }
            }
            let foundGh = await gh
            self?.gh = foundGh
            self?.tools = tools
            self?.fetchedTools = fetchedTools
            self?.toolErrors = toolErrors
        }
    }

    func toolLookupsEnded() async {
        var waited: Task<Void, Never>?
        while waited != toolLookup {
            waited = toolLookup
            await waited?.value
        }
    }

    nonisolated static func status(of account: Account, through program: URL) async throws -> AccountStatus {
        switch account.tool {
        case .claude: try await ClaudeSignIn.status(tool: program, environment: account.environment)
        case .codex: try await CodexSignIn.status(tool: program, environment: account.environment)
        }
    }

    package func findSignIns() {
        guard !isFixed else { return }
        findTools()
        let earlier = signInLookup
        signInLookup = Task { [weak self] in
            await earlier?.value
            await self?.toolLookupsEnded()
            guard
                let known = self.map({ model in
                    (gh: model.gh, own: model.tools.filter { !model.fetchedTools.contains($0.key) })
                })
            else { return }
            var ghHasSignIn = false
            if let gh = known.gh {
                do {
                    _ = try await GitHubSignIn.ghToken(gh: gh)
                    ghHasSignIn = true
                } catch {
                    if error as? GitHubError != .signedOut {
                        Self.log.error(
                            "gh could not say whether it is signed in: \(String(describing: error), privacy: .public)")
                    }
                }
            }
            let signIns = await withTaskGroup(of: (Tool, ExistingSignIn).self) { group in
                for tool in Tool.allCases {
                    group.addTask {
                        guard let program = known.own[tool] else { return (tool, .absent) }
                        do {
                            let status = try await Self.status(
                                of: Account(tool: tool, name: "", plan: "", profile: nil), through: program)
                            return (tool, status.isSignedIn ? .usable : .absent)
                        } catch {
                            return (tool, .unreadable(Snapshot.detail(of: error, tool: tool)))
                        }
                    }
                }
                var signIns: [Tool: ExistingSignIn] = [:]
                for await (tool, signIn) in group { signIns[tool] = signIn }
                return signIns
            }
            self?.ghHasSignIn = ghHasSignIn
            self?.existingSignIns = signIns
        }
    }

    func renew(_ tool: Tool) {
        guard renewing.insert(tool).inserted else { return }
        Task { [weak self, download] in
            do {
                _ = try await download.install(tool)
                self?.findTools()
                self?.owe(.limits)
            } catch {
                self?.toolErrors[tool] = error
                let cause = String(describing: error)
                Self.log.error("\(tool.programName, privacy: .public) was not renewed: \(cause, privacy: .public)")
            }
            self?.renewing.remove(tool)
        }
    }
}
