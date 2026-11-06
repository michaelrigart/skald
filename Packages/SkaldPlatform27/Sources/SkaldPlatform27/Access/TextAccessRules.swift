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
    case abortedBeforeSelecting
    case abortedAfterSelecting
    /// A paste was sent but not seen (Task 19): a late paste must still land on the range.
    case unconfirmed
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
    static let wholeValueLimit = 20_000
    static let secureRole = "AXSecureTextField"
    static let webAreaRole = "AXWebArea"
    /// After the failed query at activation.
    static let focusRetryOffsets: [Duration] = [.seconds(1), .seconds(3), .seconds(6), .seconds(10)]

    // MARK: Focus

    static func isSecure(role: String?, subrole: String?) -> Bool {
        role == secureRole || subrole == secureRole
    }

    /// Secure fields and disabled apps are never fields; web areas wait for Task 19's resolver.
    static func isFieldCandidate(role: String?, subrole: String?, appEnabled: Bool) -> Bool {
        appEnabled && !isSecure(role: role, subrole: subrole) && role != webAreaRole
    }

    /// The retry offset to wait for after `attempts` focused-element queries, the activation's included; nil stops.
    static func nextFocusRetry(afterAttempts attempts: Int, outcome: FocusAttempt) -> Duration? {
        guard outcome == .missing, attempts >= 1, attempts <= focusRetryOffsets.count else { return nil }
        return focusRetryOffsets[attempts - 1]
    }

    // MARK: Reads

    /// A ranged read first; where it fails, the whole value, but only for fields of at most 20,000 units.
    static func read(
        _ range: TextRange, ranged: () -> String?, length: () -> Int?, value: () -> String?
    ) -> String? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        if range.length == 0 { return "" }
        if let text = ranged(), text.utf16.count == range.length { return text }
        guard let total = length(), total <= wholeValueLimit, range.end <= total,
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

    /// The selection with the paragraphs it overlaps; an empty selection becomes the caret's paragraph.
    static func normalizedCapture(field: FieldID, selection: TextRange, text: String, offset: Int) -> SelectionCapture? {
        let local = TextRange(location: selection.location - offset, length: selection.length)
        guard local.location >= 0, local.end <= text.utf16.count else { return nil }
        if selection.length == 0 {
            guard let paragraph = Paragraphs.around(caret: selection.location, in: text, offset: offset) else {
                return SelectionCapture(field: field, selection: selection, selectedText: "", context: ExpectedText(range: selection, text: ""))
            }
            return SelectionCapture(
                field: field, selection: paragraph.range, selectedText: paragraph.text,
                context: ExpectedText(range: paragraph.range, text: paragraph.text)
            )
        }
        let overlapping = Paragraphs.all(in: text, offset: offset).filter {
            $0.range.location < selection.end && selection.location < $0.range.end
        }
        let context: TextRange
        if let first = overlapping.first, let last = overlapping.last {
            let location = min(first.range.location, selection.location)
            context = TextRange(location: location, length: max(last.range.end, selection.end) - location)
        } else {
            context = selection
        }
        return SelectionCapture(
            field: field, selection: selection, selectedText: substring(of: text, at: local),
            context: ExpectedText(
                range: context, text: substring(of: text, at: TextRange(location: context.location - offset, length: context.length))
            )
        )
    }

    // MARK: Replace

    /// Same field, unchanged paragraph, a clean write: then the app's write method. `currentText` reads `expected.range`.
    static func replaceStep(
        _ range: TextRange, expected: ExpectedText, isFocusedField: Bool, currentText: () -> String?, access: AppAccess
    ) -> ReplaceStep {
        guard isFocusedField else { return .refuse(.refusedOtherField) }
        guard range.location >= expected.range.location, range.end <= expected.range.end else { return .refuse(.failed) }
        guard currentText() == expected.text else { return .refuse(.refusedChanged) }
        guard access.capabilities.contains(.cleanWrite), let method = access.write else { return .refuse(.unsupported) }
        return .write(method)
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
        case .abortedBeforeSelecting, .unconfirmed:
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

    // MARK: Capabilities

    /// A one-unit range at the caret (or just before it at the end) whose bounds tell whether the app answers range bounds.
    static func boundsProbeRange(selection: TextRange, totalLength: Int) -> TextRange? {
        if selection.location < totalLength { return TextRange(location: selection.location, length: 1) }
        if selection.location > 0, selection.location <= totalLength { return TextRange(location: selection.location - 1, length: 1) }
        return nil
    }

    // MARK: Helpers

    private static func contains(_ selection: TextRange, total: Int) -> Bool {
        selection.location >= 0 && selection.length >= 0 && selection.end <= total
    }

    private static func substring(of text: String, at range: TextRange) -> String {
        (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
    }
}
