import AppKit
import ApplicationServices
import Foundation

enum ProbeMarker {
    /// A pending marker the user types and the ok marker the probe writes in its place; both pairs have the same lengths.
    struct Pair: Sendable, Equatable {
        static let tilde = Pair(pending: "~skald-probe~", replacement: "~skald-ok~")
        /// For editors that turn `~text~` into strikethrough and drop the tildes.
        static let bracket = Pair(pending: "[skald-probe]", replacement: "[skald-ok]")

        let pending: String
        let replacement: String
    }

    static let tilde = Pair.tilde
    static let bracket = Pair.bracket
    static let pairs = [Pair.tilde, .bracket]

    static var length: Int { (tilde.pending as NSString).length }

    /// The pair whose pending marker is exactly `text`; a mixed or partial marker is none.
    static func pair(pending text: String?) -> Pair? {
        pairs.first { $0.pending == text }
    }

    static func containsPending(_ text: String) -> Bool {
        pairs.contains { text.contains($0.pending) }
    }

    /// Why a marker in the value was not accepted: the caret and the offsets, as numbers only.
    static func caretSummary(of value: String, caret: CFRange?, characterCount: Int?) -> String? {
        guard let found = lastPending(in: value), range(in: value, caret: caret) == nil else { return nil }
        let end = NSRange(found, in: value)
        let caretText = caret.map { "\($0.location),\($0.length)" } ?? "none"
        return "caret \(caretText), last marker ends at \(end.location + end.length), value \((value as NSString).length) units, "
            + "characters \(characterCount.map(String.init) ?? "none")"
    }

    /// Where the last marker sits relative to the end of the value, as a unit count and a boolean only.
    static func tailSummary(of value: String) -> String? {
        guard let range = lastPending(in: value) else { return nil }
        let after = value[range.upperBound...]
        return "\(after.utf16.count) units after it, starts with a newline \(after.first?.isNewline == true)"
    }

    /// The marker the probe may replace, in UTF-16 units: one that ends the value, or one that ends exactly at a collapsed caret.
    static func range(in value: String, caret: CFRange?) -> CFRange? {
        match(in: value, caret: caret)?.range
    }

    /// The marker the probe may replace and the pair it belongs to.
    static func match(in value: String, caret: CFRange?) -> (range: CFRange, pair: Pair)? {
        let text = value as NSString
        guard text.length >= length else { return nil }
        let suffix = CFRange(location: text.length - length, length: length)
        if let pair = pair(pending: text.substring(from: suffix.location)) { return (suffix, pair) }
        guard let caret, caret.length == 0, caret.location >= length, caret.location <= text.length else { return nil }
        let candidate = CFRange(location: caret.location - length, length: length)
        return pair(pending: text.substring(with: NSRange(location: candidate.location, length: candidate.length))).map { (candidate, $0) }
    }

    private static func lastPending(in value: String) -> Range<String.Index>? {
        pairs.compactMap { value.range(of: $0.pending, options: .backwards) }.max { $0.lowerBound < $1.lowerBound }
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

struct SourceSummary: Sendable, Equatable {
    var name: String
    var containsMarker: Bool
    var textLength: Int?
    var caretLocation: Int?
    var caretLength: Int?

    init(name: String, containsMarker: Bool, textLength: Int?, caretLocation: Int?, caretLength: Int?) {
        self.name = name
        self.containsMarker = containsMarker
        self.textLength = textLength
        self.caretLocation = caretLocation
        self.caretLength = caretLength
    }

    init(name: String, text: String?, caret: CFRange?) {
        self.init(
            name: name, containsMarker: text.map(ProbeMarker.containsPending) ?? false,
            textLength: text.map { ($0 as NSString).length }, caretLocation: caret?.location, caretLength: caret?.length
        )
    }

    var description: String {
        let caret = caretLocation.map { "\($0),\(caretLength ?? 0)" } ?? "none"
        return "\(name) contains marker \(containsMarker), text length \(textLength.map(String.init) ?? "-"), caret \(caret)"
    }
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
    var sources: [SourceSummary] = []
    var baseline: BoundsBaseline?
    var formatted: AttributedSnapshot?

    var isSecure: Bool { role == ProbeLine.secureRole || subrole == ProbeLine.secureRole }
    var containsMarker: Bool { sources.contains { $0.containsMarker } || value.map(ProbeMarker.containsPending) ?? false }
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
    var pair = ProbeMarker.tilde

    var markerLocation: Int { beforeLocation + beforeLength }

    var expectedAfterWrite: String {
        (original as NSString).replacingCharacters(
            in: NSRange(location: markerLocation, length: ProbeMarker.length), with: pair.replacement
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
    var pair = ProbeMarker.tilde

    func start(method: WriteMethod) -> WriteStart {
        WriteStart(
            original: value, before: before, beforeLocation: beforeLocation, beforeLength: beforeLength,
            method: method, kind: kind, pair: pair
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
        var sources: [SourceSummary] = []
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
        var sources = [SourceSummary(name: "ranges", text: value, caret: selection)]
        var ranges = FieldContent(
            kind: .ranges, value: value, selection: selection, rangedRead: rangedRead, length: length, middle: middle, sources: sources
        )
        if forced == .ranges { return ranges }
        let rangesPlace = value.map { ProbeMarker.range(in: $0, caret: selection) != nil } ?? false
        if forced == nil, rangesPlace { return ranges }
        guard let markers = TextMarkerField(field, readsToMeasure: true) else { return ranges }
        let text = markers.text
        let textLength = text.map { ($0 as NSString).length }
        let caret = textLength.flatMap { markers.caret(textLength: $0) }
        sources.append(SourceSummary(name: "text markers", text: text, caret: caret))
        ranges.sources = sources
        let markersPlace = text.map { ProbeMarker.range(in: $0, caret: caret) != nil } ?? false
        let kind = forced ?? FieldKind.choose(
            rangesPlaceMarker: rangesPlace, markersPlaceMarker: markersPlace, selectedRangePresent: selection != nil,
            rangedReadFailed: middle != nil && !rangedRead, markersAnswer: true
        )
        guard kind == .textMarkers else { return ranges }
        return FieldContent(
            kind: .textMarkers, value: text, selection: caret, rangedRead: false, length: textLength, middle: nil, sources: sources
        )
    }

    static func editableAncestorDiagnosis(pid: pid_t) -> String {
        let field = focusedField(pid).flatMap { mayReadText($0) ? $0 : nil }
        return TextMarkerField.describeEditableAncestor(field.flatMap { TextMarkerField($0, readsToMeasure: true)?.selectionStartHasEditableAncestor })
    }

    /// Diagnostic only, numbers, booleans and roles: each step of a measurement, taken again right after an evaluation that logged no field kind.
    static func evaluationDiagnosis(pid: pid_t, measureReturnedNil: Bool, sessionCurrent: Bool) -> EvaluationDiagnosis {
        let focused = AXElement.focusedQuery(inApp: pid)
        let resolved = focusedField(pid)
        let readable = resolved.flatMap { mayReadText($0) ? $0 : nil }
        let value = readable.flatMap { readContent(of: $0).value }
        return EvaluationDiagnosis(
            measureReturnedNil: measureReturnedNil, sessionCurrent: sessionCurrent,
            outcome: .classify(
                focusedFound: focused.element != nil, resolvedFound: resolved != nil, resolvedReadable: readable != nil, valueRead: value != nil
            ),
            focusedQueryError: focused.error.rawValue,
            resolvedRole: resolved?.role,
            sameAsFocused: resolved.flatMap { field in focused.element.map { field.isSame(as: $0) } },
            resolvedMarkers: markerState(of: resolved), focusedMarkers: markerState(of: focused.element)
        )
    }

    private static func markerState(of element: AXElement?) -> MarkerFieldState {
        guard let element else { return .unavailable }
        guard mayReadText(element) else { return .notRead }
        guard let markers = TextMarkerField(element, readsToMeasure: true) else { return .unavailable }
        let length = markers.text.map { ($0 as NSString).length }
        let caret = length.flatMap { markers.caret(textLength: $0) }
        return MarkerFieldState(initialises: true, textLength: length, caretLocation: caret?.location, caretLength: caret?.length)
    }

    static func text(of field: AXElement, kind: FieldKind) -> String? {
        text(kind: kind, role: field.role, subrole: field.subrole, value: { field.value }, markerText: {
            TextMarkerField(field, readsToMeasure: true)?.text
        })
    }

    /// The field's text as it reads now, the delayed reads after a write included: nothing from a field that is
    /// secure or whose role can't be read at this moment, though it was readable when the write was prepared.
    static func text(kind: FieldKind, role: String?, subrole: String?, value: () -> String?, markerText: () -> String?) -> String? {
        guard mayReadText(role: role, subrole: subrole) else { return nil }
        return kind == .textMarkers ? markerText() : value()
    }

    static func measure(pid: pid_t, formatting: (location: Int, length: Int)?, forcing forced: FieldKind? = nil) -> FieldReading? {
        guard let field = focusedField(pid) else { return nil }
        let (role, subrole) = (field.role, field.subrole)
        var reading = FieldReading(identity: field.identity, role: role ?? "", subrole: subrole ?? "")
        guard mayReadText(role: role, subrole: subrole) else { return reading }

        let content = readContent(of: field, forcing: forced)
        reading.kind = content.kind
        reading.sources = content.sources
        reading.value = content.value
        reading.canRead = reading.value != nil
        reading.selection = content.selection
        reading.canReadSelection = reading.selection != nil
        reading.characterCount = field.numberOfCharacters
        reading.hasFrame = field.frame.flatMap { AXElement.usable($0) } != nil
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
        guard let resolved = resolvedField(pid), mayReadText(resolved.element) else { return nil }
        let field = resolved.element
        let content = readContent(of: field)
        guard let value = content.value, let match = ProbeMarker.match(in: value, caret: content.selection) else { return nil }
        let markerRange = match.range
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
            before: before, beforeLocation: beforeLocation, beforeLength: beforeLength, selectionWaitedMs: 0, kind: content.kind,
            pair: match.pair
        )
        switch content.kind {
        case .ranges:
            let selectResult = field.setSelectedRange(markerRange)
            guard selectResult == .success else { return .aborted(reason: "selection rejected (AXError \(selectResult.rawValue))") }
            guard let waited = waitForMarkerSelection({ selectionIsMarker(field, markerRange, pair: match.pair) }) else {
                let seen = describeSelection(field, markerRange, pair: match.pair)
                return .aborted(reason: "selection does not cover the marker after \(selectionWaitMs) ms (\(seen)); \(restore(content.selection, in: field))")
            }
            prepared.selectionWaitedMs = waited
        case .textMarkers:
            guard let markers = TextMarkerField(field, readsToMeasure: true) else { return .aborted(reason: "the text markers are no longer available") }
            prepared.originalMarkerSelection = markers.selectedRange.map(MarkerRangeBox.init)
            guard let anchor = TextMarkerField.anchor(for: markerRange, caret: content.selection, textLength: (value as NSString).length),
                  let end = markers.anchorMarker(anchor)
            else { return .aborted(reason: "the marker cannot be anchored to the caret or the end of the text") }
            let selectResult = markers.selectMarker(endingAt: end)
            guard selectResult == .success else {
                return .aborted(reason: "marker selection rejected (AXError \(selectResult.rawValue)); \(cancel(prepared))")
            }
            guard let waited = waitForMarkerSelection({
                mayReadText(field) && TextMarkerField.isMarkerSelection(selectedString: markers.selectedString, pair: match.pair)
            }) else {
                return .aborted(reason: "marker selection does not cover the marker after \(selectionWaitMs) ms; \(cancel(prepared))")
            }
            prepared.selectionWaitedMs = waited
        }
        return .ready(prepared)
    }

    static func writeByAccessibility(_ prepared: PreparedWrite, pid: pid_t) -> WriteStart {
        let textSettable = prepared.field.isSettable(kAXSelectedTextAttribute)
        let textResult = prepared.field.setSelectedText(prepared.pair.replacement)
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
            guard mayReadText(prepared.field) else { return "the field can no longer be read; selection left alone" }
            guard let original = prepared.originalMarkerSelection, let markers = TextMarkerField(prepared.field, readsToMeasure: true) else {
                return "no original selection to restore"
            }
            return markers.setSelection(original.range) == .success ? "original selection restored" : "restoring the selection failed"
        }
    }

    static func recheck(pid: pid_t, baseline: BoundsBaseline, kind: RecheckKind) -> BoundsRecheck {
        guard let field = focusedField(pid), mayReadText(field),
              length(of: field, value: nil) == baseline.length
        else { return .skipped }
        let bounds = field.bounds(for: baseline.range).flatMap { AXElement.usable($0) }
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

    /// The probe reads an element's text, ranged strings or text markers only when it could be a field: never a
    /// secure one, by role or subrole, nor one whose role can't be read.
    static func mayReadText(role: String?, subrole: String?) -> Bool {
        TextAccessRules.isFieldCandidate(role: role, subrole: subrole, appEnabled: true)
    }

    static func mayReadText(_ element: AXElement) -> Bool {
        mayReadText(role: element.role, subrole: element.subrole)
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

    private static func describeSelection(_ field: AXElement, _ markerRange: CFRange, pair: ProbeMarker.Pair) -> String {
        guard mayReadText(field) else { return "the field can no longer be read" }
        let range = field.selectedRange.map { "\($0.location),\($0.length)" } ?? "none"
        let text = field.selectedText.map { "\(($0 as NSString).length) units, is marker \($0 == pair.pending)" } ?? "none"
        let ranged = field.string(for: markerRange).map { "is marker \($0 == pair.pending)" } ?? "none"
        return "selected range \(range) for marker \(markerRange.location),\(markerRange.length); selected text \(text); text at marker range \(ranged)"
    }

    private static func selectionIsMarker(_ prepared: PreparedWrite) -> Bool {
        guard mayReadText(prepared.field) else { return false }
        return switch prepared.kind {
        case .ranges: selectionIsMarker(prepared.field, prepared.markerRange, pair: prepared.pair)
        case .textMarkers:
            TextMarkerField.isMarkerSelection(selectedString: TextMarkerField(prepared.field, readsToMeasure: true)?.selectedString, pair: prepared.pair)
        }
    }

    private static func selectionIsMarker(_ field: AXElement, _ markerRange: CFRange, pair: ProbeMarker.Pair) -> Bool {
        guard mayReadText(field) else { return false }
        if let selectedText = field.selectedText { return selectedText == pair.pending }
        guard let selected = field.selectedRange else { return false }
        return selected.location == markerRange.location && selected.length == markerRange.length
            && field.string(for: markerRange) == pair.pending
    }

    private static func length(of field: AXElement, value: String?) -> Int? {
        field.numberOfCharacters ?? (value ?? field.value).map { ($0 as NSString).length }
    }

    private static func ranged(_ text: String, matches value: String?, at range: CFRange) -> Bool {
        guard let value, (value as NSString).length >= range.location + range.length else { return !text.isEmpty }
        return (value as NSString).substring(with: NSRange(location: range.location, length: range.length)) == text
    }

    private static func baseline(of field: AXElement, length: Int, range: CFRange) -> BoundsBaseline? {
        guard let bounds = field.bounds(for: range).flatMap({ AXElement.usable($0) }) else { return nil }
        return BoundsBaseline(
            length: length, location: range.location, rangeLength: range.length,
            bounds: bounds, windowOrigin: field.window?.position
        )
    }
}
