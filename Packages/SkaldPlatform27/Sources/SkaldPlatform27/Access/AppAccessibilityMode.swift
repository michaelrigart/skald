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
        enable { AXUIElementSetAttributeValue(app, $0 as CFString, kCFBooleanTrue) }
    }

    /// Sets each attribute through `set`, which is the Accessibility call.
    func enable(using set: (String) -> AXError) -> [EnableResult] {
        attributesSet.map { EnableResult(attribute: $0, code: set($0).rawValue) }
    }
}

public struct EnableResult: Sendable, Equatable {
    public let attribute: String
    public let code: Int32

    public var summary: String { "\(attribute) AXError \(code)" }

    /// Asking again can't change it: the attribute was set, or the app has no such attribute. Anything else
    /// (no Accessibility grant yet, app busy, failure) may pass, so it is asked again.
    var isSettled: Bool {
        [AXError.success, .attributeUnsupported, .notImplemented].map(\.rawValue).contains(code)
    }
}

/// Which apps are already enabled. An app is recorded only once every attribute is settled, so an enable that
/// failed for a reason that can pass, such as Accessibility not granted yet, is attempted again at the next
/// activation. Kept on `AXQueue`.
struct AccessibilityEnablement {
    private var settled: Set<pid_t> = []
    private var lastReported: [pid_t: [EnableResult]] = [:]

    /// Enables `pid` through `set` unless it is settled or `mode` asks for nothing. Returns the results to log:
    /// nil when there was no attempt, or an unsettled retry came out as the one already logged.
    mutating func enable(pid: pid_t, mode: AppAccessibilityMode, using set: (String) -> AXError) -> [EnableResult]? {
        guard mode != .native, !settled.contains(pid) else { return nil }
        let results = mode.enable(using: set)
        if results.allSatisfy(\.isSettled) {
            settled.insert(pid)
            lastReported[pid] = nil
            return results
        }
        guard lastReported[pid] != results else { return nil }
        lastReported[pid] = results
        return results
    }
}
