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

    var attributesSet: [String] {
        switch self {
        case .native: []
        case .chromium: ["AXManualAccessibility"]
        case .firefox: ["AXEnhancedUserInterface"]
        }
    }

    @discardableResult
    public func enable(on app: AXUIElement) -> [EnableResult] {
        attributesSet.map { attribute in
            EnableResult(attribute: attribute, code: AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanTrue).rawValue)
        }
    }
}

public struct EnableResult: Sendable, Equatable {
    public let attribute: String
    public let code: Int32

    public var summary: String { "\(attribute) AXError \(code)" }
}
