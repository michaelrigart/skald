import ApplicationServices
import Foundation

enum FieldKind: String, Sendable {
    case ranges
    case textMarkers = "text markers"

    static func decide(selectedRangePresent: Bool, rangedReadFailed: Bool, markersAnswer: Bool) -> FieldKind {
        markersAnswer && (!selectedRangePresent || rangedReadFailed) ? .textMarkers : .ranges
    }

    /// The source that places the marker wins; with neither placing it, the usability rule decides.
    static func choose(
        rangesPlaceMarker: Bool, markersPlaceMarker: Bool, selectedRangePresent: Bool, rangedReadFailed: Bool, markersAnswer: Bool
    ) -> FieldKind {
        if rangesPlaceMarker { return .ranges }
        if markersAnswer && markersPlaceMarker { return .textMarkers }
        return decide(selectedRangePresent: selectedRangePresent, rangedReadFailed: rangedReadFailed, markersAnswer: markersAnswer)
    }
}

struct MarkerRangeBox: @unchecked Sendable { // reason: an immutable CF value, only handed back to AX on AXQueue
    let range: AXTextMarkerRange
}

/// A field whose text and caret are reachable only through text markers; every CF value is type-checked before use.
struct TextMarkerField {
    enum Anchor: Equatable {
        case selectionStart, elementEnd
    }

    static let maxTextLength = 200_000
    private static let selectedAttribute = "AXSelectedTextMarkerRange"

    let element: AXElement
    /// The probe may measure by reading a range's whole string where the app doesn't answer marker lengths;
    /// Skald itself never does, so it never reads a field to find out how long it is.
    let readsToMeasure: Bool

    init?(_ element: AXElement, readsToMeasure: Bool) {
        self.element = element
        self.readsToMeasure = readsToMeasure
        guard let range = elementRange, selectedRange != nil else { return nil }
        if let length = length(of: range), length > Self.maxTextLength { return nil }
    }

    /// A marker range's length: the app's answer, or, only where reading to measure is allowed, its string's length.
    static func measuredLength(answered: Int?, readsToMeasure: Bool, read: () -> String?) -> Int? {
        if let answered { return answered }
        guard readsToMeasure else { return nil }
        return read().map { ($0 as NSString).length }
    }

    static func checkedCaret(offset: Int?, length: Int?, textLength: Int) -> CFRange? {
        guard let offset, let length, offset >= 0, length >= 0, offset + length <= textLength else { return nil }
        return CFRange(location: offset, length: length)
    }

    #if DEBUG
    static func isMarkerSelection(selectedString: String?, pair: ProbeMarker.Pair) -> Bool {
        selectedString == pair.pending
    }
    #endif

    static func anchor(for marker: CFRange, caret: CFRange?, textLength: Int) -> Anchor? {
        if let caret, caret.length == 0, caret.location == marker.location + marker.length { return .selectionStart }
        return marker.location + marker.length == textLength ? .elementEnd : nil
    }

    static func describeEditableAncestor(_ value: Bool?) -> String {
        value.map(String.init) ?? "unsupported"
    }

    /// Diagnostic only: does the element at the selection's start marker have an editable ancestor? nil when unsupported.
    var selectionStartHasEditableAncestor: Bool? {
        guard let selected = selectedRange,
              let leaf = Self.axElement(element.parameterized("AXUIElementForTextMarker", AXTextMarkerRangeCopyStartMarker(selected)))
        else { return nil }
        return leaf.hasAttributeValue("AXEditableAncestor")
    }

    var elementRange: AXTextMarkerRange? {
        Self.markerRange(element.parameterized("AXTextMarkerRangeForUIElement", element.element))
    }

    var selectedRange: AXTextMarkerRange? {
        Self.markerRange(element.attribute(Self.selectedAttribute))
    }

    var text: String? {
        elementRange.flatMap { string(of: $0) }
    }

    var selectedString: String? {
        selectedRange.flatMap { string(of: $0) }
    }

    func caret(textLength: Int) -> CFRange? {
        guard let whole = elementRange, let selected = selectedRange else { return nil }
        let selectionStart = AXTextMarkerRangeCopyStartMarker(selected)
        let prefix = AXTextMarkerRangeCreate(nil, AXTextMarkerRangeCopyStartMarker(whole), selectionStart)
        let covered = AXTextMarkerRangeCreate(nil, selectionStart, AXTextMarkerRangeCopyEndMarker(selected))
        return Self.checkedCaret(offset: length(of: prefix), length: length(of: covered), textLength: textLength)
    }

    func anchorMarker(_ anchor: Anchor) -> AXTextMarker? {
        switch anchor {
        case .selectionStart: selectedRange.flatMap { AXTextMarkerRangeCopyStartMarker($0) }
        case .elementEnd: elementRange.flatMap { AXTextMarkerRangeCopyEndMarker($0) }
        }
    }

    #if DEBUG
    /// Selects the marker's text: from `end`, step back one marker per UTF-16 unit of the marker.
    func selectMarker(endingAt end: AXTextMarker) -> AXError {
        var start = end
        for _ in 0 ..< ProbeMarker.length {
            guard let previous = Self.marker(element.parameterized("AXPreviousTextMarkerForTextMarker", start)) else {
                return .failure
            }
            start = previous
        }
        return setSelection(AXTextMarkerRangeCreate(nil, start, end))
    }
    #endif

    func setSelection(_ range: AXTextMarkerRange) -> AXError {
        AXUIElementSetAttributeValue(element.element, Self.selectedAttribute as CFString, range)
    }

    /// The length of the element's text in UTF-16 units, measured on its marker range.
    var textLength: Int? {
        elementRange.flatMap { length(of: $0) }
    }

    var selectionStartMarker: AXTextMarker? {
        selectedRange.map { AXTextMarkerRangeCopyStartMarker($0) }
    }

    /// A marker's offset from the field's start: the length of the marker range between them.
    func offset(of marker: AXTextMarker) -> Int? {
        guard let whole = elementRange else { return nil }
        return length(of: AXTextMarkerRangeCreate(nil, AXTextMarkerRangeCopyStartMarker(whole), marker))
    }

    /// The units between two markers, `start` first.
    func length(from start: AXTextMarker, to end: AXTextMarker) -> Int? {
        length(of: AXTextMarkerRangeCreate(nil, start, end))
    }

    func next(_ marker: AXTextMarker) -> AXTextMarker? {
        Self.marker(element.parameterized("AXNextTextMarkerForTextMarker", marker))
    }

    func previous(_ marker: AXTextMarker) -> AXTextMarker? {
        Self.marker(element.parameterized("AXPreviousTextMarkerForTextMarker", marker))
    }

    /// The start marker of any element's selected marker range, without requiring the element to be a field.
    static func selectionStart(of element: AXElement) -> AXTextMarker? {
        markerRange(element.attribute(selectedAttribute)).map { AXTextMarkerRangeCopyStartMarker($0) }
    }

    private func string(of range: AXTextMarkerRange) -> String? {
        element.parameterized("AXStringForTextMarkerRange", range) as? String
    }

    private func length(of range: AXTextMarkerRange) -> Int? {
        let answered = (element.parameterized("AXLengthForTextMarkerRange", range) as? NSNumber)?.intValue
        return Self.measuredLength(answered: answered, readsToMeasure: readsToMeasure) { string(of: range) }
    }

    private static func markerRange(_ raw: CFTypeRef?) -> AXTextMarkerRange? {
        guard let raw, CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID() else { return nil }
        return (raw as! AXTextMarkerRange)
    }

    static func axElement(_ raw: CFTypeRef?) -> AXElement? {
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return AXElement(raw as! AXUIElement)
    }

    private static func marker(_ raw: CFTypeRef?) -> AXTextMarker? {
        guard let raw, CFGetTypeID(raw) == AXTextMarkerGetTypeID() else { return nil }
        return (raw as! AXTextMarker)
    }
}
