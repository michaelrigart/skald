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

    mutating func pointer(at point: CGPoint, over targets: [Target]) -> Change {
        let hit = targets.first { $0.rect.insetBy(dx: -Self.slack, dy: -Self.slack).contains(point) }?.id
        guard hit != current else { return .unchanged }
        current = hit
        return hit.map { .entered($0) } ?? .left
    }

    mutating func reset() {
        current = nil
    }
}
