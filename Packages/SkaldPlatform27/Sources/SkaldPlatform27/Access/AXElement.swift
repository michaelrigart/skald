import ApplicationServices
import Foundation

public struct AXElement: @unchecked Sendable { // reason: AXUIElement is an immutable CF reference used only on AXQueue
    public static let messagingTimeout: Float = 0.25

    public let element: AXUIElement

    public init(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        self.element = element
    }

    public static func application(pid: pid_t) -> AXElement {
        AXElement(AXUIElementCreateApplication(pid))
    }

    public static func focused(inApp pid: pid_t) -> AXElement? {
        application(pid: pid).elementAttribute(kAXFocusedUIElementAttribute)
    }

    public static func focusedApplicationPID() -> pid_t? {
        AXElement(AXUIElementCreateSystemWide()).elementAttribute(kAXFocusedApplicationAttribute)?.pid
    }

    var hash: Int { Int(CFHash(element)) }

    public func isSame(as other: AXElement) -> Bool {
        CFEqual(element, other.element)
    }

    /// The focused-element query and its error; a longer timeout applies to this query only and is reset afterwards.
    static func focusedQuery(inApp pid: pid_t, timeout: Float = messagingTimeout) -> (element: AXElement?, error: AXError) {
        let app = application(pid: pid).element
        if timeout != messagingTimeout { AXUIElementSetMessagingTimeout(app, timeout) }
        defer { if timeout != messagingTimeout { AXUIElementSetMessagingTimeout(app, messagingTimeout) } }
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &result)
        return (error == .success ? result.flatMap { axElement($0) } : nil, error)
    }

    public var role: String? { stringAttribute(kAXRoleAttribute) }
    public var subrole: String? { stringAttribute(kAXSubroleAttribute) }
    public var value: String? { stringAttribute(kAXValueAttribute) }
    public var selectedText: String? { stringAttribute(kAXSelectedTextAttribute) }
    public var window: AXElement? { elementAttribute(kAXWindowAttribute) }

    public var numberOfCharacters: Int? {
        (attribute(kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
    }

    public var selectedRange: CFRange? {
        attribute(kAXSelectedTextRangeAttribute).flatMap { Self.range($0) }
    }

    public var frame: CGRect? {
        attribute("AXFrame").flatMap { Self.rect($0) }
    }

    public var position: CGPoint? {
        guard let raw = attribute(kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &point) ? point : nil
    }

    public var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    public var identity: String {
        "\(pid ?? 0)-\(CFHash(element))"
    }

    public func string(for range: CFRange) -> String? {
        parameterized(kAXStringForRangeParameterizedAttribute, range) as? String
    }

    public func attributedString(for range: CFRange) -> NSAttributedString? {
        parameterized(kAXAttributedStringForRangeParameterizedAttribute, range) as? NSAttributedString
    }

    public func bounds(for range: CFRange) -> CGRect? {
        parameterized(kAXBoundsForRangeParameterizedAttribute, range).flatMap { Self.rect($0) }
    }

    public func isSettable(_ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    public func setSelectedRange(_ range: CFRange) -> AXError {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
    }

    public func setSelectedText(_ text: String) -> AXError {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
    }

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

    private static func axElement(_ raw: CFTypeRef) -> AXElement? {
        CFGetTypeID(raw) == AXUIElementGetTypeID() ? AXElement(raw as! AXUIElement) : nil
    }

    func elementAttribute(_ name: String) -> AXElement? {
        attribute(name).flatMap { Self.axElement($0) }
    }

    func hasAttributeValue(_ name: String) -> Bool {
        attribute(name) != nil
    }

    func attribute(_ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }

    private func stringAttribute(_ name: String) -> String? {
        attribute(name) as? String
    }

    private func parameterized(_ name: String, _ range: CFRange) -> CFTypeRef? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        return parameterized(name, parameter)
    }

    func parameterized(_ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &result) == .success
            ? result : nil
    }

    private static func range(_ raw: CFTypeRef) -> CFRange? {
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(raw as! AXValue, .cfRange, &range) ? range : nil
    }

    private static func rect(_ raw: CFTypeRef) -> CGRect? {
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(raw as! AXValue, .cgRect, &rect) ? rect : nil
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
