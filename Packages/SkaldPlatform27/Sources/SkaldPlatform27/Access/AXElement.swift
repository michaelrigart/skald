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

    public func isSame(as other: AXElement) -> Bool {
        CFEqual(element, other.element)
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
    static func focusedEditable(inApp pid: pid_t, onWebArea report: (EditableResolution) -> Void = { _ in }) -> AXElement? {
        guard let focused = focused(inApp: pid) else { return nil }
        guard needsEditableResolution(role: focused.role) else { return focused }
        let (editable, resolution) = focused.editableAtCaret()
        report(resolution)
        return editable ?? focused
    }

    private func editableAtCaret() -> (AXElement?, EditableResolution) {
        guard let range = attribute("AXSelectedTextMarkerRange") else { return (nil, EditableResolution(markerRangePresent: false)) }
        let marker = parameterized("AXStartTextMarkerForTextMarkerRange", range)
        let leaf = marker.flatMap { parameterized("AXUIElementForTextMarker", $0) }.flatMap { Self.axElement($0) }
        guard let leaf else {
            return (nil, EditableResolution(markerRangePresent: true, startMarkerPresent: marker != nil))
        }
        let ancestor = leaf.elementAttribute("AXHighestEditableAncestor") ?? leaf.elementAttribute("AXEditableAncestor")
        return (ancestor, EditableResolution(
            markerRangePresent: true, startMarkerPresent: true, leafRole: leaf.role, ancestorRole: ancestor?.role, ancestorSubrole: ancestor?.subrole
        ))
    }

    private static func axElement(_ raw: CFTypeRef) -> AXElement? {
        CFGetTypeID(raw) == AXUIElementGetTypeID() ? AXElement(raw as! AXUIElement) : nil
    }

    func elementAttribute(_ name: String) -> AXElement? {
        attribute(name).flatMap { Self.axElement($0) }
    }

    private func attribute(_ name: String) -> CFTypeRef? {
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

    private func parameterized(_ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
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

struct EditableResolution: Sendable, Equatable {
    var markerRangePresent: Bool
    var startMarkerPresent = false
    var leafRole: String?
    var ancestorRole: String?
    var ancestorSubrole: String?

    var resolved: Bool { ancestorRole != nil }

    var summary: String {
        let ancestor = ancestorRole.map { role in [role, ancestorSubrole].compactMap { $0 }.joined(separator: " ") } ?? "-"
        return "marker range present \(markerRangePresent), start marker present \(startMarkerPresent), leaf \(leafRole ?? "-"), editable ancestor \(ancestor)"
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

    func isFirst(pid: pid_t, resolved: Bool) -> Bool {
        lock.withLock { seen.insert(Key(pid: pid, resolved: resolved)).inserted }
    }

    func endSession(pid: pid_t) {
        lock.withLock { _ = seen.remove(Key(pid: pid, resolved: false)) }
    }
}
