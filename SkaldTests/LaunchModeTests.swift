import Testing
@testable import Skald

private let installed = "/Applications/Skald.app"
private let buildFolder = "/Users/x/Code/skald/build/dd.noindex/Build/Products/Debug/Skald.app"

@Test func aProbeRequestedFromABuildFolderShowsTheMoveNoticeInstead() {
    #expect(LaunchMode.resolve(isTestHost: false, probeRequested: true, bundlePath: buildFolder) == .wrongPlace)
}

@Test func aProbeRequestedFromApplicationsRunsTheProbe() {
    #expect(LaunchMode.resolve(isTestHost: false, probeRequested: true, bundlePath: installed) == .probe)
}

@Test func aNormalLaunchFromApplicationsStartsSkald() {
    #expect(LaunchMode.resolve(isTestHost: false, probeRequested: false, bundlePath: installed) == .normal)
}

@Test func aNormalLaunchFromABuildFolderShowsTheMoveNotice() {
    #expect(LaunchMode.resolve(isTestHost: false, probeRequested: false, bundlePath: buildFolder) == .wrongPlace)
}

@Test func aTestHostStaysATestHostWhereverItRunsAndWhateverItIsAskedFor() {
    #expect(LaunchMode.resolve(isTestHost: true, probeRequested: false, bundlePath: buildFolder) == .testHost)
    #expect(LaunchMode.resolve(isTestHost: true, probeRequested: true, bundlePath: buildFolder) == .testHost)
    #expect(LaunchMode.resolve(isTestHost: true, probeRequested: false, bundlePath: installed) == .testHost)
    #expect(LaunchMode.resolve(isTestHost: true, probeRequested: true, bundlePath: installed) == .testHost)
}
