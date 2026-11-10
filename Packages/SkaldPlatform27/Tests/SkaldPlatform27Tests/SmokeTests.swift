import Testing
import SkaldCore
@testable import SkaldPlatform27

@Test func linksCore() {
    #expect(SkaldCore.bundleID.hasSuffix("skald"))
}
