import ApplicationServices
import Foundation
import SkaldCore
import struct SkaldCore.TextRange

/// A field read through text markers (Mail's compose area): its whole text up to 20,000 units, the selection as
/// marker-range lengths from the field's start, and a range selected for a write by stepping markers from the
/// selection. It reports no range bounds, so these fields get the badge (finding 7). Called on `AXQueue` only.
struct TextMarkerReader: FieldReader {
    let field: TextMarkerField
    private let unread = OnceFlag()

    init?(_ element: AXElement) {
        guard let field = TextMarkerField(element, readsToMeasure: false) else { return nil }
        self.field = field
    }

    func length() -> Int? {
        field.textLength
    }

    func selection() -> TextRange? {
        guard let total = length(), let caret = field.caret(textLength: total) else { return nil }
        return TextRange(location: caret.location, length: caret.length)
    }

    func string(for range: TextRange) -> String? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        let total = length()
        guard let text = TextAccessRules.markerText(length: total, read: { field.text }) else {
            if let kind = TextAccessRules.markerUnreadKind(length: total), unread.raise() {
                PlatformLog.access.notice("text-marker field not read: \(kind, privacy: .public)")
            }
            return nil
        }
        guard range.end <= text.utf16.count else { return nil }
        return (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
    }

    func bounds(for range: TextRange) -> CGRect? {
        nil
    }

    func select(_ range: TextRange) -> Bool {
        attemptSelect(range) == .accepted
    }

    func attemptSelect(_ range: TextRange) -> SelectAttempt {
        guard let markers = markerRange(for: range) else { return .unreachable }
        return field.setSelection(markers) == .success ? .accepted : .rejected
    }

    func selectedText() -> String? {
        field.selectedString
    }

    /// `range` as markers: its start stepped to from the selection's start, its end from its start.
    private func markerRange(for range: TextRange) -> AXTextMarkerRange? {
        guard let anchor = field.selectionStartMarker, let origin = field.offset(of: anchor),
              let start = walk(from: anchor, at: origin, to: range.location)
        else { return nil }
        guard let end = range.length == 0 ? start : walk(from: start, at: range.location, to: range.end) else { return nil }
        return AXTextMarkerRangeCreate(nil, start, end)
    }

    private func walk(from marker: AXTextMarker, at origin: Int, to target: Int) -> AXTextMarker? {
        TextAccessRules.walk(
            from: marker, at: origin, to: target, next: { field.next($0) }, previous: { field.previous($0) },
            length: { field.length(from: $0, to: $1) }
        )
    }
}

/// A flag that is raised once.
final class OnceFlag: @unchecked Sendable { // reason: the flag is only touched under the lock
    private let lock = NSLock()
    private var raised = false

    /// True only for the first call.
    func raise() -> Bool {
        lock.withLock {
            defer { raised = true }
            return !raised
        }
    }
}
