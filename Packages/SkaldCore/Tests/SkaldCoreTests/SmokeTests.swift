import Testing
@testable import SkaldCore

@Test func bundleIdentifier() {
    #expect(SkaldCore.bundleID == "com.michaelrigart.skald")
}
