import Testing
@testable import SkaldCore

struct InstallLocationTests {
    @Test(arguments: [
        "/Applications/Skald.app",
        "/Applications/../Applications/Skald.app",
    ])
    func aBundleDirectlyInApplicationsIsSupported(path: String) {
        #expect(InstallLocation.isSupported(bundlePath: path))
    }

    @Test(arguments: [
        "/Applications/Utilities/Skald.app",
        "/Users/x/Applications/Skald.app",
        "/Users/x/Downloads/Skald.app",
        "/Users/x/Code/skald/build/Build/Products/Release/Skald.app",
    ])
    func aBundleElsewhereIsNotSupported(path: String) {
        #expect(!InstallLocation.isSupported(bundlePath: path))
    }
}
