import AppKit
import Observation
import SkaldCore

/// What the panel asks of its session: `PanelSession` in the app, a fake in tests.
nonisolated protocol PanelSessioning: Sendable {
    func run(_ a: EngineAction, on e: EngineKind?) async -> PanelResult
    func replace(with revised: String) async -> ReplaceOutcome
    func choose(_ language: Language) async
}

extension PanelSession: PanelSessioning {}

/// Shows and hides the panel's window: `PanelWindow` in the app, a recorder in tests.
protocol PanelPresenting: AnyObject {
    func show()
    func hide()
}

/// What a hotkey press found to work on.
enum PanelContent: Equatable {
    case field(SelectionCapture)
    /// No field is focused: the clipboard's text, and only Copy.
    case clipboard(String)
    /// A field is focused but Skald can't read it here, so there is nothing to run.
    case unreadable

    /// The clipboard is read only when no field is focused, never in place of a field that can't be read.
    static func resolve(focused: FieldID?, capture: SelectionCapture?, clipboard: () -> String?) -> PanelContent {
        guard focused != nil else { return .clipboard(clipboard() ?? "") }
        return capture.map { .field($0) } ?? .unreadable
    }
}

/// One hotkey press: the text the panel works on, and the field it came from when one was captured.
struct PanelOpening {
    struct Target {
        /// False when the app can't be written to cleanly: the panel offers Copy instead of Replace.
        let writes: Bool
        /// Activates the field's app and waits up to 1 s for the field to be focused again.
        let returnFocus: () async -> Bool
    }

    let session: any PanelSessioning
    let text: String
    /// Nil when no field was captured: the panel works on the clipboard's text and offers only Copy.
    let target: Target?
    let engines: [EngineKind]
    let engine: EngineKind
    /// Some paragraph's language can't be detected or inherited: the user picks one before any run.
    var needsLanguage = false
    /// No field was focused, so the text is the clipboard's: the panel says so above it.
    var fromClipboard = false
    /// Why there is nothing to run, when there isn't.
    var notice: String?
}

/// The panel's state: the actions on the picked engine, the result, and Replace or Copy. Replace hides the
/// window, gives the field back its focus and writes; anything short of a confirmed write reopens the panel
/// with the result, one line of reason and Copy. The clipboard is written only when Copy is pressed.
@Observable final class PanelController {
    enum Phase: Equatable {
        /// Nothing to run, and why.
        case blocked(String)
        /// Waiting for the user to pick English, Dutch or French.
        case choosingLanguage
        case ready
        case running(EngineAction, on: EngineKind)
        case finished(PanelResult)
    }

    static let noTextNotice = "Select some text, or copy some, then press the hotkey again."
    static let unreadableNotice = "Skald can't read this field here."
    static let clipboardLabel = "Text from the clipboard"

    private(set) var original = ""
    /// The text came from the clipboard, not a field.
    private(set) var fromClipboard = false
    private(set) var engines: [EngineKind] = []
    var engine: EngineKind = .thisMac
    private(set) var phase = Phase.blocked(PanelController.noTextNotice)
    /// Why Replace didn't go through, after it was tried.
    private(set) var reason: String?
    private(set) var copied = false
    private(set) var isOpen = false
    /// From Replace until its outcome; a new opening waits for it rather than dropping the outcome.
    private(set) var isReplacing = false

    @ObservationIgnored private let window: any PanelPresenting
    @ObservationIgnored private let clipboard: any Clipboard
    @ObservationIgnored private var opening: PanelOpening?
    @ObservationIgnored private var lastAction: EngineAction?
    @ObservationIgnored private var running: Task<Void, Never>?
    /// Bumped by every opening, close and run, so a late answer for an older one is dropped.
    @ObservationIgnored private var generation = 0
    /// Set once a paste went out unconfirmed: the clipboard already holds the result.
    @ObservationIgnored private var clipboardHoldsResult = false
    @ObservationIgnored private var lastReservation = 0
    /// The one opening that may still open the panel: the newest hotkey press's, until a close or its own open.
    @ObservationIgnored private var reservation: Int?

    init(window: any PanelPresenting, clipboard: any Clipboard) {
        self.window = window
        self.clipboard = clipboard
    }

    var revised: String? {
        guard case .finished(.revised(let text, _, _)) = phase else { return nil }
        return text
    }

    var offersReplace: Bool {
        guard let revised else { return false }
        return revised != original && reason == nil && opening?.target?.writes == true
    }

    var offersCopy: Bool {
        revised != nil && !clipboardHoldsResult
    }

    var canRun: Bool {
        switch phase {
        case .blocked, .choosingLanguage: false
        case .ready, .running, .finished: true
        }
    }

    /// A hotkey press's opening, reserved before its slow capture: a newer press, a close or an opening that
    /// already won makes it obsolete, and an obsolete opening never opens the panel.
    func reserveOpening() -> Int {
        lastReservation += 1
        reservation = lastReservation
        return lastReservation
    }

    /// Refused while a Replace is in flight, so its outcome is still shown.
    @discardableResult
    func open(_ opening: PanelOpening) -> Bool {
        open(opening, reserved: reserveOpening())
    }

    /// Refused for an obsolete reservation, and while a Replace is in flight.
    @discardableResult
    func open(_ opening: PanelOpening, reserved: Int) -> Bool {
        guard !isReplacing, reserved == reservation else { return false }
        reservation = nil
        running?.cancel()
        generation += 1
        self.opening = opening
        original = opening.text
        fromClipboard = opening.fromClipboard
        engines = opening.engines.contains(opening.engine) ? opening.engines : opening.engines + [opening.engine]
        engine = opening.engine
        if let notice = opening.notice {
            phase = .blocked(notice)
        } else if opening.text.allSatisfy(\.isWhitespace) {
            phase = .blocked(Self.noTextNotice)
        } else {
            phase = opening.needsLanguage ? .choosingLanguage : .ready
        }
        lastAction = nil
        resetOutcome()
        show()
        return true
    }

    func close() {
        guard !isReplacing else { return }
        reservation = nil
        running?.cancel()
        running = nil
        generation += 1
        opening = nil
        isOpen = false
        window.hide()
    }

    func run(_ action: EngineAction) {
        running?.cancel()
        running = Task { await perform(action) }
    }

    /// Picks one of the alternatives an unavailable engine offered and runs the last action on it.
    func use(_ engine: EngineKind) {
        self.engine = engine
        if let lastAction { run(lastAction) }
    }

    /// The language for the paragraphs Skald can't detect; the last action runs again when one was asked for.
    func choose(_ language: Language) async {
        guard phase == .choosingLanguage, let session = opening?.session else { return }
        let mine = generation
        await session.choose(language)
        guard mine == generation else { return }
        phase = .ready
        if let lastAction { await perform(lastAction) }
    }

    func perform(_ action: EngineAction) async {
        guard canRun, let session = opening?.session else { return }
        generation += 1
        let mine = generation
        let engine = self.engine
        lastAction = action
        resetOutcome()
        phase = .running(action, on: engine)
        let result = await session.run(action, on: engine)
        guard mine == generation else { return }
        phase = result == .needsLanguage ? .choosingLanguage : .finished(result)
    }

    func replace() async {
        guard offersReplace, let revised, let opening, let target = opening.target else { return }
        isReplacing = true
        isOpen = false
        window.hide()
        let outcome: ReplaceOutcome = await target.returnFocus() ? await opening.session.replace(with: revised) : .refusedOtherField
        isReplacing = false
        if outcome == .replaced { return close() }
        if outcome == .unconfirmed { clipboardHoldsResult = true }
        reason = Self.reason(for: outcome)
        show()
    }

    func copy() {
        guard offersCopy, let revised else { return }
        clipboard.write(revised)
        copied = true
    }

    static func reason(for outcome: ReplaceOutcome) -> String {
        switch outcome {
        case .replaced: ""
        case .unsupported: "Skald can't write in this field. Copy the result instead."
        case .clipboardBusy: "Skald can't paste while the clipboard holds protected content or an earlier fix. Copy the result instead."
        case .failed: "The change didn't go through."
        case .refusedChanged: "The text changed since Skald read it."
        case .refusedOtherField: "The field isn't focused any more."
        case .unconfirmed: "The app didn't show the change. The clipboard now holds the result."
        }
    }

    private func show() {
        isOpen = true
        window.show()
    }

    private func resetOutcome() {
        reason = nil
        copied = false
        clipboardHoldsResult = false
    }
}
