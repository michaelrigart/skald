import AppKit
import ApplicationServices
import Foundation

enum ProbeMarker {
    static let pending = "~skald-probe~"
    static let replacement = "~skald-ok~"

    static var length: Int { (pending as NSString).length }

    /// Why a marker in the value was not accepted: the caret and the offsets, as numbers only.
    static func caretSummary(of value: String, caret: CFRange?, characterCount: Int?) -> String? {
        guard let found = value.range(of: pending, options: .backwards), range(in: value, caret: caret) == nil else { return nil }
        let end = NSRange(found, in: value)
        let caretText = caret.map { "\($0.location),\($0.length)" } ?? "none"
        return "caret \(caretText), last marker ends at \(end.location + end.length), value \((value as NSString).length) units, "
            + "characters \(characterCount.map(String.init) ?? "none")"
    }

    /// Where the last marker sits relative to the end of the value, as a unit count and a boolean only.
    static func tailSummary(of value: String) -> String? {
        guard let range = value.range(of: pending, options: .backwards) else { return nil }
        let after = value[range.upperBound...]
        return "\(after.utf16.count) units after it, starts with a newline \(after.first?.isNewline == true)"
    }

    /// The marker the probe may replace, in UTF-16 units: one that ends the value, or one that ends exactly at a collapsed caret.
    static func range(in value: String, caret: CFRange?) -> CFRange? {
        let text = value as NSString
        guard text.length >= length else { return nil }
        let suffix = CFRange(location: text.length - length, length: length)
        if text.substring(from: suffix.location) == pending { return suffix }
        guard let caret, caret.length == 0, caret.location >= length, caret.location <= text.length else { return nil }
        let candidate = CFRange(location: caret.location - length, length: length)
        return text.substring(with: NSRange(location: candidate.location, length: candidate.length)) == pending ? candidate : nil
    }
}

struct BoundsBaseline: Sendable, Equatable {
    var length: Int
    var location: Int
    var rangeLength: Int
    var bounds: CGRect
    var windowOrigin: CGPoint?

    var range: CFRange { CFRange(location: location, length: rangeLength) }
}

enum RecheckKind: Sendable, Equatable {
    case windowMoved, scrolled
}

enum BoundsComparison {
    static let tolerance: CGFloat = 2

    static func isStable(_ kind: RecheckKind, old: BoundsBaseline, bounds: CGRect?, windowOrigin: CGPoint?) -> Bool {
        guard let bounds else { return false }
        switch kind {
        case .scrolled:
            return true
        case .windowMoved:
            guard let before = old.windowOrigin, let after = windowOrigin else { return false }
            let driftX = (bounds.minX - old.bounds.minX) - (after.x - before.x)
            let driftY = (bounds.minY - old.bounds.minY) - (after.y - before.y)
            return abs(driftX) <= tolerance && abs(driftY) <= tolerance
        }
    }
}

struct AttributedSnapshot: @unchecked Sendable { // reason: an immutable value, only compared
    let value: NSAttributedString
}

struct FieldReading: Sendable {
    var identity: String
    var role: String
    var subrole: String
    var value: String?
    var canRead = false
    var rangedRead = false
    var canReadSelection = false
    var hasFrame = false
    var selection: CFRange?
    var characterCount: Int?
    var kind = FieldKind.ranges
    var baseline: BoundsBaseline?
    var formatted: AttributedSnapshot?

    var isSecure: Bool { role == ProbeLine.secureRole || subrole == ProbeLine.secureRole }
}

enum WriteMethod: String, Sendable, Codable {
    case ax, paste

    init(for mode: AppAccessibilityMode) {
        self = mode == .native ? .ax : .paste
    }
}

struct WriteStart: Sendable {
    var original: String
    var before: AttributedSnapshot?
    var beforeLocation: Int
    var beforeLength: Int
    var method = WriteMethod.ax
    var kind = FieldKind.ranges

    var markerLocation: Int { beforeLocation + beforeLength }

    var expectedAfterWrite: String {
        (original as NSString).replacingCharacters(
            in: NSRange(location: markerLocation, length: ProbeMarker.length), with: ProbeMarker.replacement
        )
    }
}

struct PreparedWrite: Sendable {
    var field: AXElement
    var value: String
    var markerRange: CFRange
    var originalSelection: CFRange?
    var before: AttributedSnapshot?
    var beforeLocation: Int
    var beforeLength: Int
    var selectionWaitedMs: Int
    var kind = FieldKind.ranges
    var originalMarkerSelection: MarkerRangeBox?

    func start(method: WriteMethod) -> WriteStart {
        WriteStart(
            original: value, before: before, beforeLocation: beforeLocation, beforeLength: beforeLength,
            method: method, kind: kind
        )
    }
}

enum Preparation: Sendable {
    case ready(PreparedWrite)
    case aborted(reason: String)
}

enum PasteAttempt: Sendable {
    case sent(WriteStart, PasteOutcome)
    case aborted(reason: String)
}

enum WriteAttempt: Sendable {
    case started(WriteStart)
    case aborted(reason: String)
}

enum BoundsRecheck: Sendable {
    case skipped
    case result(stable: Bool, baseline: BoundsBaseline?)
}

enum FieldProbe {
    static let middleLength = 5
    static let contextLength = 10

    struct FieldContent {
        var kind: FieldKind
        var value: String?
        var selection: CFRange?
        var rangedRead: Bool
        var length: Int?
        var middle: CFRange?
    }

    /// The text and caret of a field: through ranges, or through text markers when the ranges are unusable.
    static func readContent(of field: AXElement, forcing forced: FieldKind? = nil) -> FieldContent {
        let value = field.value
        let selection = field.selectedRange
        let length = length(of: field, value: value)
        var rangedRead = false
        var middle: CFRange?
        if let length, length >= middleLength {
            let range = CFRange(location: max(0, length / 2 - middleLength / 2), length: middleLength)
            rangedRead = field.string(for: range).map { ranged($0, matches: value, at: range) } ?? false
            middle = range
        }
        let ranges = FieldContent(kind: .ranges, value: value, selection: selection, rangedRead: rangedRead, length: length, middle: middle)
        if forced == .ranges { return ranges }
        if forced == nil, let value, ProbeMarker.range(in: value, caret: selection) != nil { return ranges }
        let rangedReadFailed = middle != nil && !rangedRead
        guard forced == .textMarkers || selection == nil || rangedReadFailed, let markers = TextMarkerField(field) else { return ranges }
        let kind = forced ?? FieldKind.decide(selectedRangePresent: selection != nil, rangedReadFailed: rangedReadFailed, markersAnswer: true)
        guard kind == .textMarkers else { return ranges }
        let text = markers.text
        let textLength = text.map { ($0 as NSString).length }
        return FieldContent(
            kind: .textMarkers, value: text, selection: textLength.flatMap { markers.caret(textLength: $0) },
            rangedRead: false, length: textLength, middle: nil
        )
    }

    static func editableAncestorDiagnosis(pid: pid_t) -> String {
        TextMarkerField.describeEditableAncestor(focusedField(pid).flatMap { TextMarkerField($0)?.selectionStartHasEditableAncestor })
    }

    static func text(of field: AXElement, kind: FieldKind) -> String? {
        kind == .textMarkers ? TextMarkerField(field)?.text : field.value
    }

    static func measure(pid: pid_t, formatting: (location: Int, length: Int)?, forcing forced: FieldKind? = nil) -> FieldReading? {
        guard let field = focusedField(pid) else { return nil }
        var reading = FieldReading(identity: field.identity, role: field.role ?? "", subrole: field.subrole ?? "")
        if reading.isSecure { return reading }

        let content = readContent(of: field, forcing: forced)
        reading.kind = content.kind
        reading.value = content.value
        reading.canRead = reading.value != nil
        reading.selection = content.selection
        reading.canReadSelection = reading.selection != nil
        reading.characterCount = field.numberOfCharacters
        reading.hasFrame = field.frame.flatMap { usable($0) } != nil
        reading.rangedRead = content.rangedRead
        if content.kind == .ranges, let length = content.length, let range = content.middle {
            reading.baseline = baseline(of: field, length: length, range: range)
        }
        if let formatting {
            reading.formatted = field.attributedString(for: CFRange(location: formatting.location, length: formatting.length))
                .map(AttributedSnapshot.init)
        }
        return reading
    }

    static func write(pid: pid_t) -> WriteAttempt? {
        switch prepare(pid: pid, method: .ax) {
        case nil: nil
        case let .aborted(reason): .aborted(reason: reason)
        case let .ready(prepared): .started(writeByAccessibility(prepared, pid: pid))
        }
    }

    static func prepare(pid: pid_t, method: WriteMethod) -> Preparation? {
        guard let resolved = resolvedField(pid), !isSecure(resolved.element) else { return nil }
        let field = resolved.element
        let content = readContent(of: field)
        guard let value = content.value, let markerRange = ProbeMarker.range(in: value, caret: content.selection) else { return nil }
        if content.kind == .textMarkers, method != .paste {
            return .aborted(reason: "a text-marker field is written by paste only")
        }
        if method == .paste, !EditableResolution.allowsPaste(resolved.resolution, kind: content.kind) {
            return .aborted(reason: "paste refused: the field is only the deepest focused element of a web area, not a text area or field")
        }
        let beforeLocation = max(0, markerRange.location - contextLength)
        let beforeLength = markerRange.location - beforeLocation
        let before = beforeLength > 0
            ? field.attributedString(for: CFRange(location: beforeLocation, length: beforeLength)).map(AttributedSnapshot.init)
            : nil
        var prepared = PreparedWrite(
            field: field, value: value, markerRange: markerRange, originalSelection: content.selection,
            before: before, beforeLocation: beforeLocation, beforeLength: beforeLength, selectionWaitedMs: 0, kind: content.kind
        )
        switch content.kind {
        case .ranges:
            let selectResult = field.setSelectedRange(markerRange)
            guard selectResult == .success else { return .aborted(reason: "selection rejected (AXError \(selectResult.rawValue))") }
            guard let waited = waitForMarkerSelection({ selectionIsMarker(field, markerRange) }) else {
                let seen = describeSelection(field, markerRange)
                return .aborted(reason: "selection does not cover the marker after \(selectionWaitMs) ms (\(seen)); \(restore(content.selection, in: field))")
            }
            prepared.selectionWaitedMs = waited
        case .textMarkers:
            guard let markers = TextMarkerField(field) else { return .aborted(reason: "the text markers are no longer available") }
            prepared.originalMarkerSelection = markers.selectedRange.map(MarkerRangeBox.init)
            guard let anchor = TextMarkerField.anchor(for: markerRange, caret: content.selection, textLength: (value as NSString).length),
                  let end = markers.anchorMarker(anchor)
            else { return .aborted(reason: "the marker cannot be anchored to the caret or the end of the text") }
            let selectResult = markers.selectMarker(endingAt: end)
            guard selectResult == .success else {
                return .aborted(reason: "marker selection rejected (AXError \(selectResult.rawValue)); \(cancel(prepared))")
            }
            guard let waited = waitForMarkerSelection({ TextMarkerField.isMarkerSelection(selectedString: markers.selectedString) }) else {
                return .aborted(reason: "marker selection does not cover the marker after \(selectionWaitMs) ms; \(cancel(prepared))")
            }
            prepared.selectionWaitedMs = waited
        }
        return .ready(prepared)
    }

    static func writeByAccessibility(_ prepared: PreparedWrite, pid: pid_t) -> WriteStart {
        let textSettable = prepared.field.isSettable(kAXSelectedTextAttribute)
        let textResult = prepared.field.setSelectedText(ProbeMarker.replacement)
        PlatformLog.probe.notice("write sent: pid \(pid): selection on the marker after \(prepared.selectionWaitedMs) ms, selected text settable \(textSettable), set result AXError \(textResult.rawValue)")
        return prepared.start(method: .ax)
    }

    /// Phase d of the paste write: the pasteboard is staged; nothing is posted unless the selection is still on the marker in the same field.
    static func writeByPaste(_ prepared: PreparedWrite, pid: pid_t) -> PasteAttempt {
        let recheck = PasteRecheck(
            sameField: focusedField(pid).map { $0.isSame(as: prepared.field) } ?? false,
            targetIsFrontmost: AXElement.focusedApplicationPID() == pid,
            selectionOnMarker: selectionIsMarker(prepared)
        )
        if let reason = recheck.failure {
            return .aborted(reason: "\(reason) before the paste; \(cancel(prepared))")
        }
        let outcome = PasteWrite.send(
            to: pid, field: prepared.field, kind: prepared.kind, original: prepared.value,
            selectionWaitedMs: prepared.selectionWaitedMs
        )
        return .sent(prepared.start(method: .paste), outcome)
    }

    static func cancel(_ prepared: PreparedWrite) -> String {
        switch prepared.kind {
        case .ranges:
            return restore(prepared.originalSelection, in: prepared.field)
        case .textMarkers:
            guard let original = prepared.originalMarkerSelection, let markers = TextMarkerField(prepared.field) else {
                return "no original selection to restore"
            }
            return markers.setSelection(original.range) == .success ? "original selection restored" : "restoring the selection failed"
        }
    }

    static func recheck(pid: pid_t, baseline: BoundsBaseline, kind: RecheckKind) -> BoundsRecheck {
        guard let field = focusedField(pid), !isSecure(field),
              length(of: field, value: nil) == baseline.length
        else { return .skipped }
        let bounds = field.bounds(for: baseline.range).flatMap { usable($0) }
        let windowOrigin = field.window?.position
        let stable = BoundsComparison.isStable(kind, old: baseline, bounds: bounds, windowOrigin: windowOrigin)
        var updated = baseline
        if let bounds {
            updated.bounds = bounds
            updated.windowOrigin = windowOrigin
        }
        return .result(stable: stable, baseline: bounds == nil ? nil : updated)
    }

    static func focusedField(_ pid: pid_t) -> AXElement? {
        resolvedField(pid)?.element
    }

    static func resolvedField(_ pid: pid_t) -> (element: AXElement, resolution: EditableResolution?)? {
        AXElement.focusedEditable(inApp: pid, wantsMarkerReport: { WebAreaLog.shared.shouldReportMarkers(pid: pid) }) { resolution in
            let app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
            if let markers = resolution.markers {
                PlatformLog.probe.notice("text markers: \(app, privacy: .public): \(markers.summary, privacy: .public)")
            }
            guard WebAreaLog.shared.isFirst(pid: pid, resolved: resolution.resolved) else { return }
            let outcome = resolution.resolved ? "web area resolved" : "web area not resolved"
            PlatformLog.probe.notice("\(outcome, privacy: .public): \(app, privacy: .public): \(resolution.summary, privacy: .public)")
        }
    }

    static func isSecure(_ field: AXElement) -> Bool {
        field.role == ProbeLine.secureRole || field.subrole == ProbeLine.secureRole
    }

    private static func restore(_ selection: CFRange?, in field: AXElement) -> String {
        guard let selection else { return "no original selection to restore" }
        return field.setSelectedRange(selection) == .success ? "original selection restored" : "restoring the selection failed"
    }

    static let selectionWaitMs = 500
    private static let selectionPollMs = 25

    /// Some apps apply a selection asynchronously: poll until it lands, up to a deadline. Returns the wait in ms.
    private static func waitForMarkerSelection(_ isSelected: () -> Bool) -> Int? {
        var waited = 0
        while true {
            if isSelected() { return waited }
            guard waited < selectionWaitMs else { return nil }
            usleep(useconds_t(selectionPollMs * 1000))
            waited += selectionPollMs
        }
    }

    private static func describeSelection(_ field: AXElement, _ markerRange: CFRange) -> String {
        let range = field.selectedRange.map { "\($0.location),\($0.length)" } ?? "none"
        let text = field.selectedText.map { "\(($0 as NSString).length) units, is marker \($0 == ProbeMarker.pending)" } ?? "none"
        let ranged = field.string(for: markerRange).map { "is marker \($0 == ProbeMarker.pending)" } ?? "none"
        return "selected range \(range) for marker \(markerRange.location),\(markerRange.length); selected text \(text); text at marker range \(ranged)"
    }

    private static func selectionIsMarker(_ prepared: PreparedWrite) -> Bool {
        switch prepared.kind {
        case .ranges: selectionIsMarker(prepared.field, prepared.markerRange)
        case .textMarkers: TextMarkerField.isMarkerSelection(selectedString: TextMarkerField(prepared.field)?.selectedString)
        }
    }

    private static func selectionIsMarker(_ field: AXElement, _ markerRange: CFRange) -> Bool {
        if let selectedText = field.selectedText { return selectedText == ProbeMarker.pending }
        guard let selected = field.selectedRange else { return false }
        return selected.location == markerRange.location && selected.length == markerRange.length
            && field.string(for: markerRange) == ProbeMarker.pending
    }

    private static func length(of field: AXElement, value: String?) -> Int? {
        field.numberOfCharacters ?? (value ?? field.value).map { ($0 as NSString).length }
    }

    private static func ranged(_ text: String, matches value: String?, at range: CFRange) -> Bool {
        guard let value, (value as NSString).length >= range.location + range.length else { return !text.isEmpty }
        return (value as NSString).substring(with: NSRange(location: range.location, length: range.length)) == text
    }

    private static func baseline(of field: AXElement, length: Int, range: CFRange) -> BoundsBaseline? {
        guard let bounds = field.bounds(for: range).flatMap({ usable($0) }) else { return nil }
        return BoundsBaseline(
            length: length, location: range.location, rangeLength: range.length,
            bounds: bounds, windowOrigin: field.window?.position
        )
    }

    private static func usable(_ rect: CGRect) -> CGRect? {
        rect.isNull || rect.isInfinite || rect.width <= 0 || rect.height <= 0 ? nil : rect
    }
}
