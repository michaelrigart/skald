import Foundation

/// When underlines may show after a scroll. Times are instants on the caller's clock, as durations from its start.
public struct ScrollSettle<Reading: Equatable & Sendable>: Sendable {
    public enum Action: Equatable, Sendable { case hide, read(after: Duration), show }

    public static var confirmingReads: Int { 3 }
    public static var maxReads: Int { 20 }

    private enum State: Sendable {
        case showing
        case hidden(lastScroll: Duration, previous: Reading?)
        case confirming(shown: Reading, agreed: Int)
    }

    private let ceiling: Duration?
    private var state: State = .showing
    /// Reads taken since the last scroll event, across every restart a differing read causes.
    private var reads = 0

    public init(ceiling: Duration?) {
        self.ceiling = ceiling
    }

    public var isHidden: Bool {
        if case .hidden = state { return true }
        return false
    }

    public mutating func scrolled(at now: Duration) -> [Action] {
        state = .hidden(lastScroll: now, previous: nil)
        reads = 0
        guard let ceiling else { return [.hide] }
        return [.hide, .read(after: ceiling)]
    }

    public mutating func read(_ reading: Reading, at now: Duration) -> [Action] {
        guard let ceiling, reads < Self.maxReads else { return [] }
        if case .showing = state { return [] }
        reads += 1
        let spent = reads >= Self.maxReads
        switch state {
        case .showing:
            return []
        case let .hidden(lastScroll, previous):
            if !spent, let previous, previous == reading, now - lastScroll >= ceiling * 2 {
                state = .confirming(shown: reading, agreed: 0)
                return [.show, .read(after: ceiling)]
            }
            state = .hidden(lastScroll: lastScroll, previous: reading)
            return spent ? [] : [.read(after: ceiling)]
        case let .confirming(shown, agreed):
            guard shown == reading else {
                state = .hidden(lastScroll: now, previous: reading)
                return spent ? [.hide] : [.hide, .read(after: ceiling)]
            }
            let total = agreed + 1
            if total >= Self.confirmingReads {
                state = .showing
                return []
            }
            state = .confirming(shown: shown, agreed: total)
            return spent ? [] : [.read(after: ceiling)]
        }
    }

    /// A text or caret change drew fresh underlines: showing again, nothing pending.
    public mutating func redrawn() {
        state = .showing
        reads = 0
    }
}
