import SkaldCore

enum CleanWriteMethod: Sendable, Equatable {
    case accessibility, paste
}

/// What Skald may do in an app. `cleanWrite` follows from a write method, and a run-time probe can only add
/// range bounds and the field's frame.
struct AppAccess: Sendable, Equatable {
    let capabilities: AccessCapabilities
    let probed: AccessCapabilities
    let write: CleanWriteMethod?
    let mode: AppAccessibilityMode

    init(_ capabilities: AccessCapabilities, probed: AccessCapabilities = [], write: CleanWriteMethod?, mode: AppAccessibilityMode) {
        let measurable: AccessCapabilities = [.rangeBounds, .fieldFrame]
        var fixed = capabilities.subtracting(.cleanWrite)
        if write != nil { fixed.insert(.cleanWrite) }
        self.capabilities = fixed
        self.probed = probed.intersection(measurable).subtracting(fixed)
        self.write = write
        self.mode = mode
    }
}

/// Finding 7's classification per bundle identifier.
enum CapabilityTable {
    private static let full: AccessCapabilities = [.read, .rangeBounds, .fieldFrame]
    private static let badge: AccessCapabilities = [.read, .fieldFrame]

    static let known: [String: AppAccess] = [
        "com.apple.Notes": AppAccess(full, write: .accessibility, mode: .native),
        "com.apple.TextEdit": AppAccess(full, write: .accessibility, mode: .native),
        "app.zen-browser.zen": AppAccess(full, write: .paste, mode: .firefox),
        "com.tinyspeck.slackmacgap": AppAccess(badge, write: .paste, mode: .chromium),
        "org.whispersystems.signal-desktop": AppAccess(badge, write: .paste, mode: .chromium),
        "md.obsidian": AppAccess(badge, write: .paste, mode: .chromium),
        "com.apple.mail": AppAccess(badge, probed: .rangeBounds, write: .paste, mode: .native),
        "ch.protonmail.desktop": AppAccess(badge, write: nil, mode: .chromium),
    ]

    static func access(for bundleID: String) -> AppAccess {
        known[bundleID] ?? AppAccess(.read, probed: [.rangeBounds, .fieldFrame], write: nil, mode: .forBundleID(bundleID))
    }

    /// The table's capabilities plus whichever probed ones the run-time measurement found.
    static func capabilities(_ access: AppAccess, measured: AccessCapabilities) -> AccessCapabilities {
        access.capabilities.union(access.probed.intersection(measured))
    }
}
