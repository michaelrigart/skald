import AppKit

protocol Announcing {
    func announce(_ text: String)
}

/// Says `text` through VoiceOver at high priority, so a step of review mode isn't dropped behind other speech.
struct VoiceOverAnnouncer: Announcing {
    func announce(_ text: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
