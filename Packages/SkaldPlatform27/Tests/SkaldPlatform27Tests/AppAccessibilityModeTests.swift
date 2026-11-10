import ApplicationServices
import Testing
@testable import SkaldPlatform27

@Test(arguments: [
    "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "com.tinyspeck.slackmacgap",
    "org.whispersystems.signal-desktop", "ch.protonmail.desktop", "md.obsidian",
    "com.microsoft.VSCode", "com.hnc.Discord",
])
func electronAppsAreAskedForTheirTree(bundleID: String) {
    #expect(AppAccessibilityMode.forBundleID(bundleID) == .chromium)
}

@Test(arguments: ["org.mozilla.firefox", "app.zen-browser.zen"])
func firefoxFamilyIsAskedForEnhancedInterface(bundleID: String) {
    #expect(AppAccessibilityMode.forBundleID(bundleID) == .firefox)
}

@Test(arguments: ["com.apple.Notes", "com.apple.mail", "com.apple.TextEdit", "com.example.unknown"])
func everythingElseIsLeftAlone(bundleID: String) {
    #expect(AppAccessibilityMode.forBundleID(bundleID) == .native)
}

/// Counts the attribute sets an enablement makes, answering each with `error`.
private func attempt(
    _ enablement: inout AccessibilityEnablement, pid: pid_t = 100, mode: AppAccessibilityMode = .chromium, error: AXError
) -> (sets: Int, logged: [EnableResult]?) {
    var sets = 0
    let logged = enablement.enable(pid: pid, mode: mode) { _ in
        sets += 1
        return error
    }
    return (sets, logged)
}

/// Catches an app cached as enabled before Accessibility was granted: Skald launched without the grant while
/// Slack was frontmost, and Slack never exposed its fields afterwards.
@Test func aTransientFailureIsNotCachedAndTheNextActivationEnablesAgain() {
    var enablement = AccessibilityEnablement()
    #expect(attempt(&enablement, error: .apiDisabled).sets == 1)
    #expect(attempt(&enablement, error: .apiDisabled).sets == 1)
    #expect(attempt(&enablement, error: .success).sets == 1)
    #expect(attempt(&enablement, error: .success).sets == 0)
}

@Test(arguments: [AXError.apiDisabled, .cannotComplete, .failure])
func everyTransientErrorIsAskedAgain(error: AXError) {
    var enablement = AccessibilityEnablement()
    _ = attempt(&enablement, error: error)
    #expect(attempt(&enablement, error: error).sets == 1)
}

/// Catches Zen's AXEnhancedUserInterface (-25208) being set again at every activation.
@Test(arguments: [AXError.notImplemented, .attributeUnsupported, .success])
func aSettledOutcomeIsCachedAndNotRepeated(error: AXError) {
    var enablement = AccessibilityEnablement()
    #expect(attempt(&enablement, mode: .firefox, error: error).sets == 1)
    #expect(attempt(&enablement, mode: .firefox, error: error).sets == 0)
    #expect(attempt(&enablement, mode: .firefox, error: .apiDisabled).sets == 0)
}

@Test func theCacheIsPerApp() {
    var enablement = AccessibilityEnablement()
    _ = attempt(&enablement, pid: 1, error: .success)
    #expect(attempt(&enablement, pid: 2, error: .success).sets == 1)
}

@Test func aNativeAppIsNeverAsked() {
    var enablement = AccessibilityEnablement()
    #expect(attempt(&enablement, mode: .native, error: .success).sets == 0)
}

/// Catches a failing app logging a line at every activation: a retry that comes out as the line already
/// logged is silent, and a different outcome is logged again.
@Test func aRepeatedFailureIsLoggedOnceAndAChangedOutcomeAgain() {
    var enablement = AccessibilityEnablement()
    #expect(attempt(&enablement, error: .apiDisabled).logged?.map(\.code) == [AXError.apiDisabled.rawValue])
    #expect(attempt(&enablement, error: .apiDisabled).logged == nil)
    #expect(attempt(&enablement, error: .cannotComplete).logged?.map(\.code) == [AXError.cannotComplete.rawValue])
    #expect(attempt(&enablement, error: .success).logged?.map(\.code) == [AXError.success.rawValue])
    #expect(attempt(&enablement, error: .success).logged == nil)
}
