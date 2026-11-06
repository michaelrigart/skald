import Foundation
import Observation
import SkaldCore

/// What a card does once Accept has an outcome.
enum CardOutcome: Equatable {
    case close
    /// The card stays with one line of reason, and Copy fix when the clipboard doesn't already hold it.
    case keepOpen(reason: String, offersCopy: Bool)

    /// `canCopy` is false for a fix with no text to copy (a deletion), so neither the button nor the reason offers one.
    init(_ outcome: ReplaceOutcome, canCopy: Bool) {
        switch outcome {
        case .replaced: self = .close
        case .unsupported:
            self = .keepOpen(reason: "Skald can't write in this field." + (canCopy ? " Copy the fix instead." : ""), offersCopy: canCopy)
        case .clipboardBusy:
            self = .keepOpen(
                reason: "Skald can't paste while the clipboard holds protected content or an earlier fix." + (canCopy ? " Copy the fix instead." : ""),
                offersCopy: canCopy
            )
        case .failed: self = .keepOpen(reason: "The change didn't go through.", offersCopy: canCopy)
        case .refusedChanged: self = .keepOpen(reason: "The text changed since Skald checked it.", offersCopy: canCopy)
        case .refusedOtherField: self = .keepOpen(reason: "The field isn't focused any more.", offersCopy: canCopy)
        case .unconfirmed:
            self = .keepOpen(reason: "The app didn't show the change. The clipboard now holds the fix.", offersCopy: false)
        }
    }
}

/// Why the words may have moved on screen. A window move or a scroll moves them from under a ready card; a
/// caret move only redraws, since typing and clicking end a ready card by themselves.
enum LayoutChange: Equatable {
    case window, caret, scroll
}

/// The flagged words and their surroundings, cut by UTF-16 units and widened to whole characters.
struct CardContent: Equatable {
    let before: String
    let original: String
    let replacement: String
    let after: String

    init(before: String, original: String, replacement: String, after: String) {
        self.before = before
        self.original = original
        self.replacement = replacement
        self.after = after
    }

    init(issue: Issue, context: Int = 30) {
        let text = issue.chunk.text as NSString
        let edit = issue.edit.range
        let start = max(0, edit.location - context)
        let end = min(text.length, edit.end + context)
        let beforeRange = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: edit.location - start))
        let afterRange = text.rangeOfComposedCharacterSequences(for: NSRange(location: edit.end, length: end - edit.end))
        self.init(
            before: (beforeRange.location > 0 ? "…" : "") + text.substring(with: beforeRange),
            original: issue.edit.original,
            replacement: issue.edit.replacement,
            after: text.substring(with: afterRange) + (NSMaxRange(afterRange) < text.length ? "…" : "")
        )
    }
}

/// One card: its issue's fix, kept here because `accept` drops the issue whatever the outcome, and where the
/// card is between Accept and its outcome. It writes the clipboard only when Copy fix is pressed.
@Observable final class IssueCardModel: Identifiable {
    struct Actions {
        let accept: (UUID) async -> ReplaceOutcome
        let ignore: (UUID) -> Void
        let neverFlag: (UUID) -> Void
    }

    enum Phase: Equatable {
        case ready
        case working
        case finished(reason: String, offersCopy: Bool)
        case closed
    }

    let id: UUID
    let field: FieldID
    let content: CardContent
    /// False in a read-only app, where Copy fix takes Accept's place.
    let writes: Bool
    private(set) var phase: Phase = .ready
    private(set) var copied = false
    /// The write's outcome, once Accept has one.
    private(set) var outcome: ReplaceOutcome?
    @ObservationIgnored var onClose: (() -> Void)?
    /// Called once Accept's outcome left the card open with its reason.
    @ObservationIgnored var onFinish: (() -> Void)?

    @ObservationIgnored private let fix: String
    @ObservationIgnored private let clipboard: any Clipboard
    @ObservationIgnored private let actions: Actions

    init(issue: Issue, writes: Bool, clipboard: any Clipboard, actions: Actions) {
        id = issue.id
        field = issue.key.field
        content = CardContent(issue: issue)
        fix = issue.edit.replacement
        self.writes = writes
        self.clipboard = clipboard
        self.actions = actions
    }

    var offersAccept: Bool { phase == .ready && writes }

    var offersCopy: Bool {
        switch phase {
        case .ready: return !writes && !fix.isEmpty
        case .finished(_, let offersCopy): return offersCopy
        case .working, .closed: return false
        }
    }

    /// The word Never flag adds, or nil for an insertion, which has none.
    var neverFlagWord: String? {
        phase == .ready && !content.original.isEmpty ? content.original : nil
    }

    func accept() async {
        guard offersAccept else { return }
        phase = .working
        let outcome = await actions.accept(id)
        self.outcome = outcome
        switch CardOutcome(outcome, canCopy: !fix.isEmpty) {
        case .close: close()
        case .keepOpen(let reason, let offersCopy):
            phase = .finished(reason: reason, offersCopy: offersCopy)
            onFinish?()
        }
    }

    func copyFix() {
        guard offersCopy else { return }
        clipboard.write(fix)
        copied = true
    }

    func ignore() {
        guard phase == .ready else { return }
        actions.ignore(id)
        close()
    }

    func neverFlag() {
        guard neverFlagWord != nil else { return }
        actions.neverFlag(id)
        close()
    }

    func close() {
        guard phase != .closed else { return }
        phase = .closed
        onClose?()
    }

    /// A ready card lasts while its issue is visible in its field. Once Accept runs, the pipeline has dropped
    /// the issue: a working card stays until its outcome, and a finished one while its field keeps focus, so
    /// it doesn't follow the user to another app.
    func survives(visible: Set<UUID>, in field: FieldID?) -> Bool {
        switch phase {
        case .ready: field == self.field && visible.contains(id)
        case .working: true
        case .finished: field == self.field
        case .closed: false
        }
    }

    /// A ready card is anchored to words that a window move or a scroll has moved; any other card stays.
    func survives(_ change: LayoutChange) -> Bool {
        phase != .ready || change == .caret
    }
}

/// A field's issues as a parked card compares them: where each is and what it changes, not its id, which a
/// re-check renews.
struct IssueMark: Hashable {
    let key: ParagraphKey
    let edit: Edit

    static func marks(of issues: [Issue], except id: UUID? = nil) -> Set<IssueMark> {
        Set(issues.filter { $0.id != id }.map { IssueMark(key: $0.key, edit: $0.edit) })
    }
}

/// Ruling R121: a card whose write finishes after focus moved to another field doesn't stay over the other app.
/// An unconfirmed one is hidden and shown again when its field is focused again, so Skald still says the clipboard
/// holds the fix; it is dropped when another card opens or when its field's issues changed. Any other outcome closes.
struct CardParking {
    enum AfterFinish: Equatable {
        case stays, hides, closes
    }

    struct Parked {
        let card: IssueCardModel
        let anchor: CGRect
        let screen: CGRect
        /// The field's other issues when Accept ran.
        let issues: Set<IssueMark>
    }

    private(set) var parked: Parked?

    /// Where `card` goes now that its write finished, `focused` being the field focused now.
    mutating func finished(
        _ card: IssueCardModel, focused: FieldID?, anchor: CGRect, screen: CGRect, issues: Set<IssueMark>
    ) -> AfterFinish {
        guard case .finished = card.phase, focused != card.field else { return .stays }
        guard card.outcome == .unconfirmed else { return .closes }
        parked = Parked(card: card, anchor: anchor, screen: screen, issues: issues)
        return .hides
    }

    /// The parked card to show again, once, when a snapshot for its field shows the issues it was parked with.
    mutating func received(_ snapshot: IssueSnapshot) -> Parked? {
        guard let parked, snapshot.field == parked.card.field else { return nil }
        self.parked = nil
        return IssueMark.marks(of: snapshot.issues) == parked.issues ? parked : nil
    }

    mutating func otherCardOpened() {
        parked = nil
    }
}
