import ApplicationServices
import CoreGraphics
import SkaldCore
import Testing
@testable import SkaldPlatform27

/// The overlay redraws on window moves only if the observer tells them apart from the field's own notifications.
@Test(arguments: [kAXWindowMovedNotification, kAXWindowResizedNotification])
func aWindowMoveOrResizeIsAGeometryChange(name: String) {
    #expect(ObservedNotification(name) == .windowGeometry)
}

@Test func focusValueAndSelectionKeepTheirMeaning() {
    #expect(ObservedNotification(kAXFocusedUIElementChangedNotification) == .focus)
    #expect(ObservedNotification(kAXValueChangedNotification) == .value)
    #expect(ObservedNotification(kAXSelectedTextChangedNotification) == .selection)
}

@Test func anotherNotificationMeansNothing() {
    #expect(ObservedNotification(kAXTitleChangedNotification) == nil)
}

/// Catches a session that stops registering focus or window geometry on the app: what it registers is
/// exactly what `register` asks for, read back through the mapping `received` uses.
@Test func aSessionRegistersFocusAndBothWindowGeometryNotificationsOnTheApp() {
    var registrations = ApplicationRegistrations()
    var asked: [String] = []
    registrations.register { asked.append($0); return true }
    #expect(asked.map { ObservedNotification($0) } == [.focus, .windowGeometry, .windowGeometry])
    #expect(Set(asked) == [kAXFocusedUIElementChangedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification])
    #expect(registrations.missing.isEmpty)
}

/// Catches a window notification refused once and never asked for again.
@Test func aRefusedRegistrationIsRetriedAndOnlyThatOne() {
    var registrations = ApplicationRegistrations()
    registrations.register { $0 != kAXWindowResizedNotification }
    #expect(registrations.missing == [kAXWindowResizedNotification])
    var retried: [String] = []
    registrations.register { retried.append($0); return true }
    #expect(retried == [kAXWindowResizedNotification])
    #expect(registrations.missing.isEmpty)
}

/// Moving the caret can scroll the field, so the overlay must hear of it.
@Test func aCaretMoveIsACaretGeometryChange() {
    let field = FieldID(app: "com.example.editor", token: "1")
    #expect(TextAccessRules.geometryChange(for: .caretMoved(field)) == .caret)
    #expect(TextAccessRules.geometryChange(for: .edited(field)) == nil)
    #expect(TextAccessRules.geometryChange(for: .focused(field)) == nil)
    #expect(TextAccessRules.geometryChange(for: .focused(nil)) == nil)
}

@Test func boundsAreReadForEveryRangeInOrder() {
    let ranges = [TextRange(location: 0, length: 3), TextRange(location: 4, length: 2), TextRange(location: 7, length: 5)]
    let rect = CGRect(x: 10, y: 20, width: 30, height: 16)
    let bounds = TextAccessRules.bounds(of: ranges) { $0.location == 4 ? .missing : .found(rect) }
    #expect(bounds == [rect, nil, rect])
}

/// A hung app answers no range; asking for each would hold `AXQueue` for one timeout per range.
@Test func aTimeoutStopsTheBoundsReadsAndLeavesTheRestEmpty() {
    let ranges = (0..<5).map { TextRange(location: $0 * 4, length: 3) }
    let rect = CGRect(x: 10, y: 20, width: 30, height: 16)
    var asked: [Int] = []
    let bounds = TextAccessRules.bounds(of: ranges) { range in
        asked.append(range.location)
        return range.location == 4 ? .timedOut : .found(rect)
    }
    #expect(asked == [0, 4])
    #expect(bounds == [rect, nil, nil, nil, nil])
}
