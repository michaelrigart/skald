import ApplicationServices
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

@Test func theWindowNotificationsAreTheOnesRegisteredOnTheApp() {
    #expect(Set(ObservedNotification.windowNotifications) == [kAXWindowMovedNotification, kAXWindowResizedNotification])
}
