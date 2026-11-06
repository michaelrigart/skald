import AppKit
import Observation
import SkaldCore

/// What the panel asks of its session: `PanelSession` in the app, a fake in tests.
nonisolated protocol PanelSessioning: Sendable {
    func run(_ a: EngineAction, on e: EngineKind?) async -> PanelResult
    func replace(with revised: String) async -> ReplaceOutcome
}

extension PanelSession: PanelSessioning {}

/// Shows and hides the panel's window: `PanelWindow` in the app, a recorder in tests.
protocol PanelPresenting: AnyObject {
    func show()
    func hide()
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
}

/// The panel's state: the actions on the picked engine, the result, and Replace or Copy. Replace hides the
/// window, gives the field back its focus and writes; anything short of a confirmed write reopens the panel
/// with the result, one line of reason and Copy. The clipboard is written only when Copy is pressed.
@Observable final class PanelController {
    enum Phase: Equatable {
        case empty
        case ready
        case running(EngineAction)
        case finished(PanelResult)
    }

    private(set) var original = ""
    private(set) var engines: [EngineKind] = []
    var engine: EngineKind = .thisMac
    private(set) var phase = Phase.empty
    /// Why Replace didn't go through, after it was tried.
    private(set) var reason: String?
    private(set) var copied = false
    private(set) var isOpen = false

    @ObservationIgnored private let window: any PanelPresenting
    @ObservationIgnored private let clipboard: any Clipboard
    @ObservationIgnored private var opening: PanelOpening?
    @ObservationIgnored private var lastAction: EngineAction?
    @ObservationIgnored private var running: Task<Void, Never>?
    /// Bumped by every opening and run, so a late answer for an older one is dropped.
    @ObservationIgnored private var generation = 0
    /// Set once a paste went out unconfirmed: the clipboard already holds the result.
    @ObservationIgnored private var clipboardHoldsResult = false

    init(window: any PanelPresenting, clipboard: any Clipboard) {
        self.window = window
        self.clipboard = clipboard
    }

    var revised: String? {
        guard case .finished(.revised(let text, _, _)) = phase else { return nil }
        return text
    }

    var offersReplace: Bool {
        revised != nil && reason == nil && opening?.target?.writes == true
    }

    var offersCopy: Bool {
        revised != nil && !clipboardHoldsResult
    }

    var canRun: Bool {
        phase != .empty
    }

    func open(_ opening: PanelOpening) {
        running?.cancel()
        generation += 1
        self.opening = opening
        original = opening.text
        engines = opening.engines.contains(opening.engine) ? opening.engines : opening.engines + [opening.engine]
        engine = opening.engine
        phase = opening.text.allSatisfy(\.isWhitespace) ? .empty : .ready
        lastAction = nil
        resetOutcome()
        show()
    }

    func close() {
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

    func perform(_ action: EngineAction) async {
        guard canRun, let session = opening?.session else { return }
        generation += 1
        let mine = generation
        lastAction = action
        resetOutcome()
        phase = .running(action)
        let result = await session.run(action, on: engine)
        guard mine == generation, result != .failed(.cancelled) else { return }
        phase = .finished(result)
    }

    func replace() async {
        guard offersReplace, let revised, let opening, let target = opening.target else { return }
        let mine = generation
        isOpen = false
        window.hide()
        let focused = await target.returnFocus()
        guard mine == generation else { return }
        guard focused else { return reopen(Self.reason(for: .refusedOtherField)) }
        let outcome = await opening.session.replace(with: revised)
        guard mine == generation else { return }
        if outcome == .replaced { return close() }
        if outcome == .unconfirmed { clipboardHoldsResult = true }
        reopen(Self.reason(for: outcome))
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
        case .failed: "The change didn't go through."
        case .refusedChanged: "The text changed since Skald read it."
        case .refusedOtherField: "The field isn't focused any more."
        case .unconfirmed: "The app didn't show the change. The clipboard now holds the result."
        }
    }

    private func reopen(_ reason: String) {
        self.reason = reason
        show()
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
