import ApplicationServices

public enum AppAccessibilityMode: Sendable {
    case native, chromium, firefox

    private static let chromiumApps: Set<String> = [
        "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac",
        "com.tinyspeck.slackmacgap", "org.whispersystems.signal-desktop", "ch.protonmail.desktop",
        "md.obsidian", "com.microsoft.VSCode", "com.hnc.Discord",
    ]

    private static let firefoxApps: Set<String> = ["org.mozilla.firefox", "app.zen-browser.zen"]

    public static func forBundleID(_ bundleID: String) -> Self {
        if chromiumApps.contains(bundleID) { return .chromium }
        if firefoxApps.contains(bundleID) { return .firefox }
        return .native
    }

    public func enable(on app: AXUIElement) {
        switch self {
        case .native:
            break
        case .chromium:
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        case .firefox:
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }
}
