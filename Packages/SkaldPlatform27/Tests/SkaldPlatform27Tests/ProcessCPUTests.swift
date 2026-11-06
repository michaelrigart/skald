#if DEBUG
import Darwin
import Foundation
import Testing
@testable import SkaldPlatform27

/// CPU time of this process's waited-for children, from the kernel's own accounting in microseconds.
private func childrenCPUNanoseconds() -> UInt64 {
    var usage = rusage()
    getrusage(RUSAGE_CHILDREN, &usage)
    func nanoseconds(_ time: timeval) -> UInt64 { UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_usec) * 1_000 }
    return nanoseconds(usage.ru_utime) + nanoseconds(usage.ru_stime)
}

/// Load-independent: the child runs until it has used 50 ms of CPU, however long a loaded machine takes to give
/// it that, and the CPU time a sample reads for it matches the kernel's within 20 %, so a sample left in Mach
/// ticks (about 2.4 % of the nanoseconds) fails.
@Test func aSampleReadsAChildsCPUTimeAsTheKernelCountsIt() async throws {
    let before = childrenCPUNanoseconds()
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = ["-c", "while :; do :; done"]
    try child.run()
    let pid = child.processIdentifier
    var reaped = false
    defer {
        if !reaped {
            kill(pid, SIGKILL)
            child.waitUntilExit()
        }
    }
    let deadline = ContinuousClock.now + .seconds(30)
    while (CPUSample.take(tree: pid).nanoseconds[pid] ?? 0) < 50_000_000, ContinuousClock.now < deadline {
        try await ContinuousClock().sleep(for: .milliseconds(20))
    }
    kill(pid, SIGSTOP)
    let sampled = try #require(CPUSample.take(tree: pid).nanoseconds[pid])
    kill(pid, SIGKILL)
    child.waitUntilExit()
    reaped = true
    let counted = childrenCPUNanoseconds() - before
    try #require(counted > 0)
    let ratio = Double(sampled) / Double(counted)
    #expect(ratio > 0.8 && ratio < 1.2, "sampled \(sampled) ns, counted \(counted) ns")
}

@Test func treeIncludesTheRootAndItsChildren() {
    #expect(ProcessTree.members(of: getpid()).first == getpid())
    #expect(ProcessTree.members(of: getppid()).contains(getpid()))
}
#endif
