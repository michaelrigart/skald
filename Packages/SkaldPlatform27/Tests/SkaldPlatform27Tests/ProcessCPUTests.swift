import Darwin
import Foundation
import Testing
@testable import SkaldPlatform27

@Test func busyChildReadsAsAboutOneCore() async throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = ["-c", "while :; do :; done"]
    try child.run()
    defer {
        child.terminate()
        child.waitUntilExit()
    }
    let start = CPUSample.take(tree: child.processIdentifier)
    try await ContinuousClock().sleep(for: .milliseconds(400))
    let end = CPUSample.take(tree: child.processIdentifier)
    let percent = end.percent(since: start)
    #expect(percent > 30 && percent < 150, "measured \(percent)")
}

@Test func treeIncludesTheRootAndItsChildren() {
    #expect(ProcessTree.members(of: getpid()).first == getpid())
    #expect(ProcessTree.members(of: getppid()).contains(getpid()))
}
