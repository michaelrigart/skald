import Darwin
import Testing
@testable import SkaldPlatform27

@Test func busyProcessReadsAsAboutOneCore() {
    let own = getpid()
    let start = CPUSample.take(tree: own)
    var sink = 0.0
    let deadline = ContinuousClock.now + .milliseconds(300)
    while ContinuousClock.now < deadline {
        for step in 1...2_000 { sink += Double(step).squareRoot() }
    }
    let end = CPUSample.take(tree: own)
    #expect(sink > 0)
    let percent = end.percent(since: start)
    #expect(percent > 50 && percent < 150, "measured \(percent)")
}

@Test func treeIncludesTheRootAndItsChildren() {
    #expect(ProcessTree.members(of: getpid()).first == getpid())
    #expect(ProcessTree.members(of: getppid()).contains(getpid()))
}
