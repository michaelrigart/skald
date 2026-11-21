import Foundation
import SkaldCore

/// Review mode's state machine, its keys and what its effects do, free of windows: the controller supplies `Actions`.
/// Keys are held exactly while the mode holds them (`ReviewMode.holdsKeys`): `hold` before the first card, and every
/// `.close` releases them.
final class ReviewSession {
    struct Actions {
        /// The focused field's published list, read when the mode opens; `snapshot` carries it from then on.
        let issues: () -> [Issue]
        /// The focused field's app has a clean write.
        let writes: () -> Bool
        /// Shows the issue's card; `index` counts from 0 in the list `count` long.
        let show: (Issue, _ index: Int, _ count: Int) -> Void
        /// Accepts through the shown card, so it says "Applying the fix…"; the guess's index, or nil for the fix.
        let accept: (UUID, Int?) async -> ReplaceOutcome
        let copy: (UUID) -> Void
        let dismiss: (UUID) -> Void
        /// The "Checking…" card.
        let showChecking: () -> Void
        /// Closes the cards that are ready and the "Checking…" card.
        let close: () -> Void
    }

    static let checking = "Checking…"

    private let keys: ReviewKeys
    private let announcer: any Announcing
    private let sleep: (Duration) async throws -> Void
    private let actions: Actions
    private var mode = ReviewMode()
    /// The focused field's list as the mode sees it: the last snapshot, less what the user dismissed and the
    /// pipeline has not dropped yet.
    private var issues: [Issue] = []
    private var dismissed: Set<UUID> = []
    /// The guess the accept being run was asked for with the mouse; nil for ↩.
    private var alternative: Int?
    private var wait: Task<Void, Never>?
    /// Bumped by every `.close`, so the outcome of a write or the end of a wait that belongs to an earlier opening
    /// reaches nothing.
    private var epoch = 0

    init(keys: ReviewKeys, announcer: any Announcing, sleep: @escaping (Duration) async throws -> Void, actions: Actions) {
        self.keys = keys
        self.announcer = announcer
        self.sleep = sleep
        self.actions = actions
    }

    var isOpen: Bool { mode.holdsKeys }

    /// "Grammar: word, change to wordt. 2 of 5"; `index` counts from 0.
    static func announcement(label: String, index: Int, count: Int) -> String {
        "\(label). \(index + 1) of \(count)"
    }

    /// The shortcut: opens on the first issue, or leaves. The keys are held before anything is shown.
    func toggle() {
        if isOpen { return run(mode.left()) }
        issues = actions.issues()
        dismissed = []
        let effects = mode.toggle(issues: issues)
        guard !effects.isEmpty else { return }
        guard keys.hold({ [weak self] in self?.pressed($0) }) else {
            Log.ui.notice("review mode not opened: the system refused a key")
            _ = mode.left()
            return
        }
        run(effects)
    }

    /// Every snapshot of the focused field, in the order the pipeline publishes them: the mode waits for a recheck
    /// that follows an unchecked one. Another field leaves.
    func snapshot(_ new: [Issue], checked: Bool, sameField: Bool) {
        guard sameField else { return left() }
        guard isOpen else { return }
        dismissed.formIntersection(new.map(\.id))
        issues = new.filter { !dismissed.contains($0.id) }
        run(mode.issuesChanged(issues, checked: checked))
    }

    /// The field's text changed.
    func edited() {
        run(mode.edited())
    }

    /// A click elsewhere, a pause, the overlay stopping.
    func left() {
        run(mode.left())
    }

    /// The card's Accept or guess button: ↩'s step, for a guess when `alternative` is given.
    func accept(alternative: Int?) {
        self.alternative = alternative
        pressed(.accept)
        self.alternative = nil
    }

    /// The card's Dismiss button: ⌫'s step.
    func dismiss() {
        pressed(.dismiss)
    }

    private func pressed(_ key: ReviewMode.Key) {
        run(mode.key(key, issues: issues, writes: actions.writes()))
    }

    private func run(_ effects: [ReviewMode.Effect]) {
        for effect in effects {
            switch effect {
            case .show(let id): show(id)
            case .accept(let id): accepting(id)
            case .copy(let id): actions.copy(id)
            case .dismiss(let id):
                dismissed.insert(id)
                issues.removeAll { $0.id == id }
                actions.dismiss(id)
            case .wait(let id, let duration): checkingWait(id, duration)
            case .close: close()
            }
        }
    }

    private func show(_ id: UUID) {
        guard let index = issues.firstIndex(where: { $0.id == id }) else { return }
        actions.show(issues[index], index, issues.count)
        announcer.announce(Self.announcement(label: IssueCardModel.label(for: issues[index]), index: index, count: issues.count))
    }

    private func accepting(_ id: UUID) {
        let epoch = epoch
        let alternative = alternative
        Task { [actions] in
            let outcome = await actions.accept(id, alternative)
            guard epoch == self.epoch else { return }
            run(mode.finished(outcome))
        }
    }

    private func checkingWait(_ id: UUID, _ duration: Duration) {
        actions.showChecking()
        announcer.announce(Self.checking)
        wait?.cancel()
        let epoch = epoch
        wait = Task { [sleep] in
            do { try await sleep(duration) } catch { return }
            guard !Task.isCancelled, epoch == self.epoch else { return }
            run(mode.waitEnded(id))
        }
    }

    private func close() {
        epoch += 1
        wait?.cancel()
        wait = nil
        dismissed = []
        keys.release()
        actions.close()
    }
}
