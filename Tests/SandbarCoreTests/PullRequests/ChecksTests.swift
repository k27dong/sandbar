import Foundation
import SandbarCore
import Testing

struct ChecksTests {
    static let earlier = Sample.now - 600
    static let later = Sample.now - 60

    @Test func noRunsHaveNoVerdict() {
        #expect(Checks(counting: []) == Checks(verdict: nil))
    }

    @Test func requiredPassWithOptionalFailureIsPassed() {
        let runs = [
            CheckRun(name: "build", isRequired: true, outcome: .passed, startedAt: Self.earlier),
            CheckRun(name: "unused-exports", isRequired: false, outcome: .failed, startedAt: Self.earlier),
        ]
        #expect(Checks(counting: runs) == Checks(verdict: .passed))
    }

    @Test func optionalFailureCountsWhenNothingIsRequired() {
        let runs = [
            CheckRun(name: "build", isRequired: false, outcome: .passed, startedAt: Self.earlier),
            CheckRun(name: "lint", isRequired: false, outcome: .failed, startedAt: Self.earlier),
        ]
        #expect(Checks(counting: runs) == Checks(verdict: .failed, failed: ["lint"]))
    }

    @Test func requiredFailureBeatsRequiredRunning() {
        let runs = [
            CheckRun(name: "build", isRequired: true, outcome: .running, startedAt: Self.later),
            CheckRun(name: "test", isRequired: true, outcome: .failed, startedAt: Self.earlier),
        ]
        #expect(Checks(counting: runs) == Checks(verdict: .failed, failed: ["test"]))
    }

    @Test func newerPassReplacesOlderFailure() {
        let runs = [
            CheckRun(name: "test", isRequired: true, outcome: .failed, startedAt: Self.earlier),
            CheckRun(name: "test", isRequired: true, outcome: .passed, startedAt: Self.later),
        ]
        #expect(Checks(counting: runs) == Checks(verdict: .passed))
    }

    @Test func rerunNotYetStartedReplacesOlderFailure() {
        let runs = [
            CheckRun(name: "test", isRequired: true, outcome: .failed, startedAt: Self.earlier),
            CheckRun(name: "test", isRequired: true, outcome: .running, startedAt: nil),
        ]
        #expect(Checks(counting: runs) == Checks(verdict: .running))
    }

    @Test func newestRunIsChosenBeforeTheRequiredFilter() {
        let runs = [
            CheckRun(name: "test", isRequired: true, outcome: .failed, startedAt: Self.earlier),
            CheckRun(name: "test", isRequired: true, outcome: .passed, startedAt: Self.later),
            CheckRun(name: "unused-exports", isRequired: false, outcome: .failed, startedAt: Self.later),
        ]
        #expect(Checks(counting: runs) == Checks(verdict: .passed))
    }

    @Test func failedNamesFollowTheGivenOrder() {
        let runs = [
            CheckRun(name: "e2e-chrome", isRequired: true, outcome: .failed, startedAt: Self.earlier),
            CheckRun(name: "build", isRequired: true, outcome: .passed, startedAt: Self.earlier),
            CheckRun(name: "lint", isRequired: true, outcome: .failed, startedAt: Self.earlier),
        ]
        #expect(Checks(counting: runs) == Checks(verdict: .failed, failed: ["e2e-chrome", "lint"]))
    }
}
