import Foundation
import SkaldCore
import struct SkaldCore.TextRange

enum FocusAttempt: Sendable, Equatable {
    case found, missing
    /// Focus or the frontmost app changed since the retries began.
    case moved
}

/// How a write ended, for the caret rule.
enum WriteEnd: Sendable, Equatable {
    case confirmed
    case abortedAfterSelecting
    /// A paste was sent but not seen (Task 19): a late paste must still land on the range.
    case unconfirmed
}

enum MarkerStep: Sendable, Equatable {
    case reached, next, previous, refused
}

enum ReplaceStep: Sendable, Equatable {
    case refuse(ReplaceOutcome)
    case write(CleanWriteMethod)
}

/// The text a field holds around the caret, as read.
struct WindowRead: Sendable, Equatable {
    let text: String
    let offset: Int
    let selection: TextRange
    let totalLength: Int
}

/// The decisions behind `SystemTextAccess`, kept free of Accessibility calls.
enum TextAccessRules {
    static let secureRole = "AXSecureTextField"
    static let webAreaRole = "AXWebArea"
    /// After the failed query at activation.
    static let focusRetryOffsets: [Duration] = [.seconds(1), .seconds(3), .seconds(6), .seconds(10)]

    // MARK: Focus

    static func isSecure(role: String?, subrole: String?) -> Bool {
        role == secureRole || subrole == secureRole
    }

    /// Secure fields, elements whose role can't be read and disabled apps are never fields. A web area comes here
    /// only once `EditableResolver` found it to be its own editable field.
    static func isFieldCandidate(role: String?, subrole: String?, appEnabled: Bool) -> Bool {
        guard appEnabled, let role else { return false }
        return !isSecure(role: role, subrole: subrole)
    }

    /// The retry offset to wait for after `attempts` focused-element queries, the activation's included; nil stops.
    static func nextFocusRetry(afterAttempts attempts: Int, outcome: FocusAttempt) -> Duration? {
        guard outcome == .missing, attempts >= 1, attempts <= focusRetryOffsets.count else { return nil }
        return focusRetryOffsets[attempts - 1]
    }

    // MARK: Reads

    /// Ranges when their read window can be read (a working ranged read, or the full value of a short field),
    /// else text markers when they answer, else nothing. The markers are asked only when the ranges fail.
    static func source(rangesReadable: Bool, markersAnswer: () -> Bool) -> FieldKind? {
        if rangesReadable { return .ranges }
        return markersAnswer() ? .textMarkers : nil
    }

    /// Why a text-marker field gives no text, as a fixed kind: the app doesn't answer marker lengths (Skald never
    /// reads the field to measure it), or the field is over the read limit. nil when its length allows a read.
    static func markerUnreadKind(length: Int?) -> String? {
        guard let length else { return "the app gives no marker lengths" }
        return length > ReadWindow.limit ? "over the read limit" : nil
    }

    /// A text-marker field's whole text, only when it is at most 20,000 units and agrees with its marker length.
    static func markerText(length: Int?, read: () -> String?) -> String? {
        guard let length, length <= ReadWindow.limit, let text = read(), text.utf16.count == length else { return nil }
        return text
    }

    /// A ranged read first; where it fails, the whole value, but only for fields of at most 20,000 units.
    static func read(
        _ range: TextRange, ranged: () -> String?, length: () -> Int?, value: () -> String?
    ) -> String? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        if range.length == 0 { return "" }
        if let text = ranged(), text.utf16.count == range.length { return text }
        guard let total = length(), total <= ReadWindow.limit, range.end <= total,
              let whole = value(), whole.utf16.count == total
        else { return nil }
        return substring(of: whole, at: range)
    }

    /// The read window around the caret (Task 4's `ReadWindow`), or nil when the field has no usable selection.
    static func window(of reader: some FieldReader) -> WindowRead? {
        guard let total = reader.length(), let selection = reader.selection(), contains(selection, total: total) else { return nil }
        let window = ReadWindow.range(totalLength: total, caret: selection.location)
        guard let text = reader.string(for: window) else { return nil }
        return WindowRead(text: text, offset: window.location, selection: selection, totalLength: total)
    }

    static func snapshot(of field: FieldID, reader: some FieldReader) -> FieldSnapshot? {
        window(of: reader).map {
            FieldSnapshot(field: field, text: $0.text, offset: $0.offset, selection: $0.selection, totalLength: $0.totalLength)
        }
    }

    // MARK: Capture

    /// The read windows around both ends of the selection, joined, so the selection is always inside.
    static func captureWindow(selection: TextRange, totalLength: Int) -> TextRange {
        let start = ReadWindow.range(totalLength: totalLength, caret: selection.location)
        let end = ReadWindow.range(totalLength: totalLength, caret: selection.end)
        let location = min(start.location, end.location)
        return TextRange(location: location, length: max(start.end, end.end) - location)
    }

    static func capture(of field: FieldID, reader: some FieldReader) -> SelectionCapture? {
        guard let total = reader.length(), let selection = reader.selection(), contains(selection, total: total) else { return nil }
        let window = captureWindow(selection: selection, totalLength: total)
        guard let text = reader.string(for: window) else { return nil }
        return normalizedCapture(field: field, selection: selection, text: text, offset: window.location)
    }

    /// The selection with the whole lines it touches as context, so the context is bounded by line breaks or
    /// the window's ends; an empty selection becomes the caret's paragraph.
    static func normalizedCapture(field: FieldID, selection: TextRange, text: String, offset: Int) -> SelectionCapture? {
        let units = Array(text.utf16)
        let local = TextRange(location: selection.location - offset, length: selection.length)
        guard local.location >= 0, local.end <= units.count else { return nil }
        var start = local.location
        while start > 0, !Paragraphs.isLineBreak(units[start - 1]) { start -= 1 }
        var end = local.end
        while end < units.count, !Paragraphs.isLineBreak(units[end]) { end += 1 }
        let line = TextRange(location: start, length: end - start)
        let context = ExpectedText(range: TextRange(location: start + offset, length: line.length), text: substring(of: text, at: line))
        if selection.length == 0 {
            return SelectionCapture(field: field, selection: context.range, selectedText: context.text, context: context)
        }
        return SelectionCapture(field: field, selection: selection, selectedText: substring(of: text, at: local), context: context)
    }

    // MARK: Replace

    /// Same field, unchanged paragraph, a clean write: then the app's write method.
    static func replaceStep(
        _ range: TextRange, expected: ExpectedText, isFocusedField: Bool,
        read: (TextRange) -> String?, length: () -> Int?, access: AppAccess
    ) -> ReplaceStep {
        guard isFocusedField else { return .refuse(.refusedOtherField) }
        guard range.location >= expected.range.location, range.end <= expected.range.end else { return .refuse(.failed) }
        guard paragraphUnchanged(expected, read: read, length: length) else { return .refuse(.refusedChanged) }
        guard access.capabilities.contains(.cleanWrite), let method = access.write else { return .refuse(.unsupported) }
        return .write(method)
    }

    /// The whole paragraph is still there: its text, and a line break or the field's edge on either side of it.
    static func paragraphUnchanged(_ expected: ExpectedText, read: (TextRange) -> String?, length: () -> Int?) -> Bool {
        guard read(expected.range) == expected.text, let total = length(), expected.range.end <= total else { return false }
        let range = expected.range
        let before = range.location == 0 || isLineBreak(read(TextRange(location: range.location - 1, length: 1)))
        let after = range.end == total || isLineBreak(read(TextRange(location: range.end, length: 1)))
        return before && after
    }

    /// The expected paragraph once `text` replaced `range` in it.
    static func applying(_ text: String, at range: TextRange, to expected: ExpectedText) -> ExpectedText {
        let local = NSRange(location: range.location - expected.range.location, length: range.length)
        let revised = (expected.text as NSString).replacingCharacters(in: local, with: text)
        return ExpectedText(
            range: TextRange(location: expected.range.location, length: revised.utf16.count), text: revised
        )
    }

    // MARK: The caret

    /// Where the user's selection goes back to after a write, or nil to leave the selection alone.
    static func caretTarget(user: TextRange, replaced: TextRange, replacementLength: Int, end: WriteEnd) -> TextRange? {
        switch end {
        case .confirmed:
            let start = shifted(user.location, replaced: replaced, replacementLength: replacementLength)
            let finish = shifted(user.end, replaced: replaced, replacementLength: replacementLength)
            return TextRange(location: start, length: finish - start)
        case .abortedAfterSelecting:
            return user
        case .unconfirmed:
            return nil
        }
    }

    /// Restore only while the field is still focused and its selection is still the one Skald left.
    static func restoresCaret(stillFocused: Bool, current: TextRange?, left: TextRange?) -> Bool {
        guard stillFocused, let current, let left else { return false }
        return current == left
    }

    /// A position before the range stays, one after it moves by the length change, one inside stays within the replacement.
    private static func shifted(_ position: Int, replaced: TextRange, replacementLength: Int) -> Int {
        if position >= replaced.end {
            return position + replacementLength - replaced.length
        }
        if position <= replaced.location { return position }
        return min(position, replaced.location + replacementLength)
    }

    // MARK: Paste writes

    /// The selection is exactly `range` and holds the text expected there.
    static func selectionCovers(_ range: TextRange, text: String, selection: TextRange?, selectedText: String?) -> Bool {
        selection == range && selectedText == text
    }

    /// What the field shows after ⌘V: the paragraph with the replacement applied, the original one, or another.
    static func pasteRead(
        original: ExpectedText, revised: ExpectedText, read: (TextRange) -> String?, length: () -> Int?
    ) -> PastePlan.Read {
        guard length() != nil else { return .unreadable }
        if paragraphUnchanged(revised, read: read, length: length) { return .expected }
        if paragraphUnchanged(original, read: read, length: length) { return .original }
        return .other
    }

    /// The caret rule for a paste write: the selection to set, or nil to leave it. Skald left the caret after the
    /// replacement after a confirmed paste, and the range selected after an abort.
    static func pasteCaret(
        user: TextRange, replaced: TextRange, replacementLength: Int, end: WriteEnd, current: TextRange?, stillFocused: Bool
    ) -> TextRange? {
        guard let target = caretTarget(user: user, replaced: replaced, replacementLength: replacementLength, end: end) else { return nil }
        let left = end == .confirmed ? TextRange(location: replaced.location + replacementLength, length: 0) : replaced
        guard restoresCaret(stillFocused: stillFocused, current: current, left: left), current != target else { return nil }
        return target
    }

    /// The expected text at `range`, which lies inside `expected`.
    static func text(of expected: ExpectedText, at range: TextRange) -> String? {
        let local = TextRange(location: range.location - expected.range.location, length: range.length)
        guard local.location >= 0, local.end <= expected.text.utf16.count else { return nil }
        return substring(of: expected.text, at: local)
    }

    // MARK: Selecting by text markers

    static let markerReach = 2_000

    /// One step toward `target` from a walk that began at `origin`: refused beyond the reach, past the target
    /// (a grapheme wider than one unit at the boundary), or after twice as many steps as units to cover.
    static func markerStep(origin: Int, current: Int?, target: Int, steps: Int) -> MarkerStep {
        let distance = abs(target - origin)
        guard target >= 0, distance <= markerReach, let current else { return .refused }
        if current == target { return .reached }
        guard steps < 2 * distance else { return .refused }
        if origin <= target { return current < target ? .next : .refused }
        return current > target ? .previous : .refused
    }

    /// The marker `target` units from the field's start, stepping from `start` (at `origin`) and summing the length
    /// of each single step, so no step measures from the field's start; nil when the step rule refuses.
    static func walk<Marker>(
        from start: Marker, at origin: Int, to target: Int, next: (Marker) -> Marker?, previous: (Marker) -> Marker?,
        length: (Marker, Marker) -> Int?
    ) -> Marker? {
        var current = start
        var offset = origin
        var steps = 0
        while true {
            switch markerStep(origin: origin, current: offset, target: target, steps: steps) {
            case .reached: return current
            case .refused: return nil
            case .next:
                guard let following = next(current), let units = length(current, following) else { return nil }
                current = following
                offset += units
            case .previous:
                guard let preceding = previous(current), let units = length(preceding, current) else { return nil }
                current = preceding
                offset -= units
            }
            steps += 1
        }
    }

    // MARK: Capabilities

    /// A one-unit range at the caret (or just before it at the end) whose bounds tell whether the app answers range bounds.
    static func boundsProbeRange(selection: TextRange, totalLength: Int) -> TextRange? {
        if selection.location < totalLength { return TextRange(location: selection.location, length: 1) }
        if selection.location > 0, selection.location <= totalLength { return TextRange(location: selection.location - 1, length: 1) }
        return nil
    }

    /// The bounds of each range, read in order. After the first read the app doesn't answer in time, the rest
    /// are not asked for, so a hung app holds `AXQueue` for one timeout, not one per range.
    static func bounds(of ranges: [TextRange], read: (TextRange) -> BoundsRead) -> [CGRect?] {
        var result: [CGRect?] = []
        for range in ranges {
            switch read(range) {
            case .found(let rect): result.append(rect)
            case .missing: result.append(nil)
            case .timedOut: return result + Array(repeating: nil, count: ranges.count - result.count)
            }
        }
        return result
    }

    /// The geometry change a field event means: a caret move can scroll the field.
    static func geometryChange(for event: FieldEvent) -> GeometryChange? {
        if case .caretMoved = event { return .caret }
        return nil
    }

    // MARK: Helpers

    private static func isLineBreak(_ text: String?) -> Bool {
        guard let text, text.utf16.count == 1, let unit = text.utf16.first else { return false }
        return Paragraphs.isLineBreak(unit)
    }

    private static func contains(_ selection: TextRange, total: Int) -> Bool {
        selection.location >= 0 && selection.length >= 0 && selection.end <= total
    }

    private static func substring(of text: String, at range: TextRange) -> String {
        (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
    }
}
