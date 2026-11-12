import Foundation

package struct CheckRun: Hashable, Sendable {
    package enum Outcome: Sendable { case passed, failed, running }

    package var name: String
    package var isRequired: Bool
    package var outcome: Outcome
    package var startedAt: Date?

    package init(name: String, isRequired: Bool, outcome: Outcome, startedAt: Date?) {
        self.name = name
        self.isRequired = isRequired
        self.outcome = outcome
        self.startedAt = startedAt
    }
}

package struct Checks: Codable, Hashable, Sendable {
    package enum Verdict: String, Codable, Sendable { case passed, running, failed }

    package var verdict: Verdict?
    package var failed: [String]

    package init(verdict: Verdict?, failed: [String] = []) {
        self.verdict = verdict
        self.failed = failed
    }

    package init(counting runs: [CheckRun]) {
        var newest: [CheckRun] = []
        var indexByName: [String: Int] = [:]
        for run in runs {
            guard let index = indexByName[run.name] else {
                indexByName[run.name] = newest.count
                newest.append(run)
                continue
            }
            let noStart = Date.distantFuture  // a run asked for again and not yet started is newer than any that ran
            if (run.startedAt ?? noStart) >= (newest[index].startedAt ?? noStart) { newest[index] = run }
        }
        let required = newest.filter(\.isRequired)
        let counted = required.isEmpty ? newest : required
        failed = counted.filter { $0.outcome == .failed }.map(\.name)
        if counted.isEmpty {
            verdict = nil
        } else if !failed.isEmpty {
            verdict = .failed
        } else if counted.contains(where: { $0.outcome == .running }) {
            verdict = .running
        } else {
            verdict = .passed
        }
    }
}
