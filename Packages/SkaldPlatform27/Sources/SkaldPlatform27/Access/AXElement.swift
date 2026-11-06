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
        AXTimeouts.record(error)
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
        boundsRead(for: range).rect
    }

    /// The bounds with the call's error, so a caller can tell an app that didn't answer from a range without bounds.
    func boundsRead(for range: CFRange) -> (rect: CGRect?, error: AXError) {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return (nil, .illegalArgument) }
        var result: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &result
        )
        AXTimeouts.record(error)
        return (error == .success ? result.flatMap { Self.rect($0) } : nil, error)
    }

    /// A rect worth drawing at: finite, with a positive width and height.
    static func usable(_ rect: CGRect) -> CGRect? {
        rect.isNull || rect.isInfinite || rect.width <= 0 || rect.height <= 0 ? nil : rect
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
        defer { AXQueue.textWritten() }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
    }

    static func axElement(_ raw: CFTypeRef) -> AXElement? {
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
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &result)
        AXTimeouts.record(error)
        return error == .success ? result : nil
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
        let error = AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &result)
        AXTimeouts.record(error)
        return error == .success ? result : nil
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
