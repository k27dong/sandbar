import SandbarCore

extension AppModel {
    package typealias Selection = PullRequestList.Selection
    typealias Row = PullRequestList.Row

    func rows(of stack: Stack) -> [Row] {
        PullRequestList.rows(
            of: stack, isOpen: openStacks.contains(stack.id), topFirst: preferences.stackOrder == .topFirst)
    }

    private var selectableRows: [Row] {
        showsLists ? list.rows(openStacks: openStacks, topFirst: preferences.stackOrder == .topFirst) : []
    }

    package func moveSelection(by step: Int) {
        selection = PullRequestList.selection(after: selection, movedBy: step, in: selectableRows)
    }

    package func openSelection() {
        switch selectableRows.first(where: { $0.selection == selection }) {
        case .pullRequest(let pullRequest): open(pullRequest)
        case .fold(let stack): openStacks.formSymmetricDifference([stack.id])
        case nil: break
        }
    }
}
