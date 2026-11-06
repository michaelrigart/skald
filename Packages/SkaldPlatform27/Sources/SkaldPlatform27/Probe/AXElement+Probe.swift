import ApplicationServices
import Foundation

/// The probe's own route from a focused web area to its editable element: the editable ancestor at the caret,
/// else a bounded search of the focused descendants. Checking while typing uses `EditableResolver`.
extension AXElement {
    static func needsEditableResolution(role: String?) -> Bool {
        role == "AXWebArea"
    }

    /// The focused element; for a web area, the editable element holding the caret when the text markers lead to one.
    static func focusedEditable(
        inApp pid: pid_t, wantsMarkerReport: () -> Bool = { false }, onWebArea report: (EditableResolution) -> Void = { _ in }
    ) -> (element: AXElement, resolution: EditableResolution?)? {
        guard let focused = focused(inApp: pid) else { return nil }
        guard needsEditableResolution(role: focused.role) else { return (focused, nil) }
        var (editable, resolution) = focused.editableAtCaret()
        if editable == nil {
            if FocusedSearchCache.shared.isKnownEmpty(focused, pid: pid) {
                resolution.search = SearchOutcome(found: false, preferred: false, role: nil, subrole: nil, visited: 0, elapsedMs: 0)
            } else {
                let start = DispatchTime.now()
                let result = FocusedDescendantSearch.find(
                    in: focused,
                    elapsedMs: { Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000) },
                    info: { $0.searchInfo }, children: { $0.children }
                )
                resolution.search = SearchOutcome(
                    found: result.found != nil, preferred: result.preferred, role: result.found?.role, subrole: result.found?.subrole,
                    visited: result.visited, elapsedMs: result.elapsedMs
                )
                editable = result.found
                if result.found == nil { FocusedSearchCache.shared.rememberEmpty(focused, pid: pid) }
            }
        }
        if !resolution.resolved, wantsMarkerReport() { resolution.markers = focused.textMarkerReport() }
        report(resolution)
        return (editable ?? focused, resolution)
    }

    private func editableAtCaret() -> (AXElement?, EditableResolution) {
        guard let range = attribute("AXSelectedTextMarkerRange") else { return (nil, EditableResolution(markerRangePresent: false)) }
        let marker = parameterized("AXStartTextMarkerForTextMarkerRange", range) ?? Self.startMarker(ofRange: range)
        let leaf = marker.flatMap { parameterized("AXUIElementForTextMarker", $0) }.flatMap { Self.axElement($0) }
        guard let leaf else {
            return (nil, EditableResolution(markerRangePresent: true, startMarkerPresent: marker != nil))
        }
        let ancestor = leaf.elementAttribute("AXHighestEditableAncestor") ?? leaf.elementAttribute("AXEditableAncestor")
        return (ancestor, EditableResolution(
            markerRangePresent: true, startMarkerPresent: true, leafRole: leaf.role, ancestorRole: ancestor?.role, ancestorSubrole: ancestor?.subrole
        ))
    }

    private func textMarkerReport() -> TextMarkerReport {
        let elementRange = parameterized("AXTextMarkerRangeForUIElement", element)
        let selected = attribute("AXSelectedTextMarkerRange")
        func index(_ marker: CFTypeRef?) -> Int? {
            marker.flatMap { parameterized("AXIndexForTextMarker", $0) }.flatMap { ($0 as? NSNumber)?.intValue }
        }
        return TextMarkerReport(
            elementRangePresent: elementRange != nil,
            elementTextLength: elementRange.flatMap { parameterized("AXLengthForTextMarkerRange", $0) }
                .flatMap { ($0 as? NSNumber)?.intValue },
            selectedRangePresent: selected != nil,
            startIndex: index(selected.flatMap { parameterized("AXStartTextMarkerForTextMarkerRange", $0) }),
            endIndex: index(selected.flatMap { parameterized("AXEndTextMarkerForTextMarkerRange", $0) }),
            selectedLength: selected.flatMap { parameterized("AXLengthForTextMarkerRange", $0) }
                .flatMap { ($0 as? NSNumber)?.intValue }
        )
    }

    private var searchInfo: SearchNodeInfo {
        guard isFocused else { return SearchNodeInfo(role: nil, focused: false, selectionSettable: false) }
        return SearchNodeInfo(role: role, focused: true, selectionSettable: isSettable(kAXSelectedTextRangeAttribute))
    }

    private var isFocused: Bool {
        (attribute(kAXFocusedAttribute) as? NSNumber)?.boolValue == true
    }

    private var children: [AXElement] {
        guard let raw = attribute(kAXChildrenAttribute), CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        let array = raw as! CFArray
        return (0 ..< CFArrayGetCount(array)).compactMap { index in
            CFArrayGetValueAtIndex(array, index).flatMap { Self.axElement(Unmanaged<CFTypeRef>.fromOpaque($0).takeUnretainedValue()) }
        }
    }

    /// WebKit does not answer the parameterized start-marker attribute; the public function reads it from the range itself.
    private static func startMarker(ofRange range: CFTypeRef) -> CFTypeRef? {
        guard CFGetTypeID(range) == AXTextMarkerRangeGetTypeID() else { return nil }
        return AXTextMarkerRangeCopyStartMarker(range as! AXTextMarkerRange)
    }
}

struct SearchOutcome: Sendable, Equatable {
    var found: Bool
    var preferred: Bool
    var role: String?
    var subrole: String?
    var visited: Int
    var elapsedMs: Int
}

struct TextMarkerReport: Sendable, Equatable {
    var elementRangePresent: Bool
    var elementTextLength: Int?
    var selectedRangePresent: Bool
    var startIndex: Int?
    var endIndex: Int?
    var selectedLength: Int?

    var summary: String {
        func number(_ value: Int?) -> String { value.map(String.init) ?? "-" }
        return "element range present \(elementRangePresent), element text length \(number(elementTextLength)), "
            + "selected range present \(selectedRangePresent), start index \(number(startIndex)), "
            + "end index \(number(endIndex)), selected length \(number(selectedLength))"
    }
}

struct EditableResolution: Sendable, Equatable {
    var markerRangePresent: Bool
    var startMarkerPresent = false
    var leafRole: String?
    var ancestorRole: String?
    var ancestorSubrole: String?
    var search: SearchOutcome?
    var markers: TextMarkerReport?

    var resolved: Bool { ancestorRole != nil || search?.found == true }

    static func allowsPaste(_ resolution: EditableResolution?, kind: FieldKind = .ranges) -> Bool {
        guard let search = resolution?.search else { return true }
        if search.preferred { return true }
        return kind == .textMarkers && !search.found
    }

    var summary: String {
        let ancestor = ancestorRole.map { role in [role, ancestorSubrole].compactMap { $0 }.joined(separator: " ") } ?? "-"
        let base = "marker range present \(markerRangePresent), start marker present \(startMarkerPresent), leaf \(leafRole ?? "-"), editable ancestor \(ancestor)"
        guard let search else { return base }
        return base + ", search found \(search.found) preferred \(search.preferred) role \(search.role ?? "-") subrole \(search.subrole ?? "-"), "
            + "visited \(search.visited), \(search.elapsedMs) ms"
    }
}

final class WebAreaLog: @unchecked Sendable { // reason: the seen set is only touched under the lock
    static let shared = WebAreaLog()

    private struct Key: Hashable {
        let pid: pid_t
        let resolved: Bool
    }

    private let lock = NSLock()
    private var seen: Set<Key> = []
    private var markerReported: Set<pid_t> = []

    func isFirst(pid: pid_t, resolved: Bool) -> Bool {
        lock.withLock { seen.insert(Key(pid: pid, resolved: resolved)).inserted }
    }

    func shouldReportMarkers(pid: pid_t) -> Bool {
        lock.withLock { markerReported.insert(pid).inserted }
    }

    func endSession(pid: pid_t) {
        lock.withLock {
            _ = seen.remove(Key(pid: pid, resolved: false))
            markerReported.remove(pid)
        }
    }
}
