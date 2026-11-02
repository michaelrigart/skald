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
