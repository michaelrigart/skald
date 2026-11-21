import Foundation

public struct ReviewMode: Sendable {
    public enum Key: Sendable, CaseIterable { case next, previous, accept, dismiss, leave }

    public enum Phase: Equatable, Sendable { case closed, showing(UUID), applying(UUID), awaiting(UUID) }

    public enum Effect: Equatable, Sendable {
        /// Open this issue's card.
        case show(UUID)
        /// Start the write; report its outcome with `finished`.
        case accept(UUID)
        /// No clean write here: copy the fix, the card stays.
        case copy(UUID)
        case dismiss(UUID)
        /// Say "Checking…", and call `waitEnded` with this id after the duration.
        case wait(UUID, Duration)
        /// Free the keys and close a card that is only offering its choices.
        case close
    }

    public static let recheckWait: Duration = .seconds(6)

    public init() {}

    public private(set) var phase: Phase = .closed
    /// The field offset the mode stands on: the shown issue's start.
    public private(set) var position = 0
    /// Whether an unchecked snapshot, the pipeline's suspension on Skald's own write, has come since the accept
    /// started. A checked snapshot before it still holds the old list.
    private var suspended = false

    public var holdsKeys: Bool { phase != .closed }

    /// The shortcut: opens on the first issue (nothing when there is none), or leaves.
    public mutating func toggle(issues: [Issue]) -> [Effect] {
        if holdsKeys { return left() }
        guard let first = issues.first else { return [] }
        return show(first)
    }

    public mutating func key(_ key: Key, issues: [Issue], writes: Bool) -> [Effect] {
        switch phase {
        case .closed:
            return []
        case .applying, .awaiting:
            return key == .leave ? left() : []
        case .showing(let id):
            let index = issues.firstIndex { $0.id == id }
            switch key {
            case .leave:
                return left()
            case .next:
                if let index {
                    return issues.indices.contains(index + 1) ? show(issues[index + 1]) : []
                }
                return issues.first { $0.fieldRange.location > position }.map { show($0) } ?? []
            case .previous:
                if let index {
                    return index > 0 ? show(issues[index - 1]) : []
                }
                return issues.last { $0.fieldRange.location < position }.map { show($0) } ?? []
            case .accept:
                guard index != nil else { return [] }
                guard writes else { return [.copy(id)] }
                phase = .applying(id)
                suspended = false
                return [.accept(id)]
            case .dismiss:
                guard index != nil else { return [] }
                return [.dismiss(id)] + showNearest(in: issues.filter { $0.id != id })
            }
        }
    }

    /// The outcome of the write `.accept(id)` started.
    public mutating func finished(_ outcome: ReplaceOutcome) -> [Effect] {
        guard case .applying(let id) = phase else { return [] }
        guard outcome == .replaced else { return close() }
        phase = .awaiting(id)
        return [.wait(id, Self.recheckWait)]
    }

    /// A snapshot for the focused field.
    public mutating func issuesChanged(_ issues: [Issue], checked: Bool) -> [Effect] {
        switch phase {
        case .closed:
            return []
        case .applying:
            suspended = suspended || !checked
            return []
        case .showing(let id):
            if let shown = issues.first(where: { $0.id == id }) {
                position = shown.fieldRange.location
                return []
            }
            return showNearest(in: issues)
        case .awaiting:
            suspended = suspended || !checked
            return checked && suspended ? showNearest(in: issues) : []
        }
    }

    public mutating func waitEnded(_ id: UUID) -> [Effect] {
        phase == .awaiting(id) ? close() : []
    }

    /// The field's text changed.
    public mutating func edited() -> [Effect] {
        if case .showing = phase { return close() }
        return []
    }

    /// A focus change, a click elsewhere, a pause, the overlay stopping.
    public mutating func left() -> [Effect] {
        holdsKeys ? close() : []
    }

    private mutating func close() -> [Effect] {
        phase = .closed
        return [.close]
    }

    private mutating func show(_ issue: Issue) -> [Effect] {
        phase = .showing(issue.id)
        position = issue.fieldRange.location
        return [.show(issue.id)]
    }

    /// The first issue at or after the position, else the last before it, else the mode ends.
    private mutating func showNearest(in issues: [Issue]) -> [Effect] {
        let nearest = issues.first { $0.fieldRange.location >= position } ?? issues.last
        return nearest.map { show($0) } ?? close()
    }
}
