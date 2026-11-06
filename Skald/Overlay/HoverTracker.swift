import CoreGraphics
import Foundation

/// Which underlined word the pointer is over, from one pointer position to the next. The controller starts
/// the card's wait on `entered` and cancels it on `left`.
struct HoverTracker {
    struct Target {
        let id: UUID
        /// The word's line box in AppKit coordinates; its underline runs along the bottom.
        let rect: CGRect
    }

    enum Change: Equatable {
        case unchanged, entered(UUID), left
    }

    /// The pointer counts this far outside a word, so the 2-point underline is easy to rest on.
    static let slack: CGFloat = 2

    private(set) var current: UUID?

    /// `covered` is the open card's frame: words under it can't be pointed at, only the card can.
    mutating func pointer(at point: CGPoint, over targets: [Target], covered: CGRect? = nil) -> Change {
        let hidden = covered?.contains(point) ?? false
        let hit = hidden ? nil : targets.first { Self.reach($0.rect).contains(point) }?.id
        guard hit != current else { return .unchanged }
        current = hit
        return hit.map { .entered($0) } ?? .left
    }

    mutating func reset() {
        current = nil
    }

    /// A hover card stays open while the pointer is on its word, within the same slack the word is entered
    /// with, on the card, or between the two.
    static func keepsCard(at point: CGPoint, anchor: CGRect, card: CGRect) -> Bool {
        reach(anchor).union(card).contains(point)
    }

    private static func reach(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: -slack, dy: -slack)
    }
}
