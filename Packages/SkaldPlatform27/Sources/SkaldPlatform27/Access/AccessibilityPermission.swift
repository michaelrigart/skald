import ApplicationServices

/// Skald's Accessibility grant, so the app target makes no Accessibility calls of its own.
public enum AccessibilityPermission {
    public static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt, which lists Skald in the Accessibility pane, switched off.
    public static func request() {
        // The value of kAXTrustedCheckOptionPrompt, a global var Swift 6 won't read without isolation.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}
