import Foundation
import Testing
@testable import SkaldPlatform27

/// Counts reads; touched only inside AXQueue jobs.
private final class Reads: @unchecked Sendable { // reason: only touched inside AXQueue jobs, which run one at a time
    var count = 0
    let cache = PerJob<String>()

    func read() -> String {
        cache.value {
            count += 1
            return "text \(count)"
        }
    }
}

@Test func aValueIsReadOncePerJobAndAgainInTheNextJob() async {
    let queue = AXQueue()
    let reads = Reads()
    let first = await queue.run { [reads.read(), reads.read(), reads.read()] }
    #expect(first == ["text 1", "text 1", "text 1"])
    let second = await queue.run { reads.read() }
    #expect(second == "text 2")
    #expect(await queue.run { reads.count } == 2)
}

@Test func aTextWriteInsideAJobMakesTheNextReadReadAgain() async {
    let queue = AXQueue()
    let reads = Reads()
    let texts = await queue.run {
        let before = reads.read()
        AXQueue.textWritten()
        return [before, reads.read(), reads.read()]
    }
    #expect(texts == ["text 1", "text 2", "text 2"])
}

/// An app's switch, and whether it was asked while another job still held the queue.
private final class QueuedSwitch: @unchecked Sendable { // reason: state is only touched under the lock
    private let lock = NSLock()
    private var on = true
    private var blocked = true
    private var askedWhileBlocked = false
    private var asked = false
    private var blockerRunning = false

    var isOn: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }

    var wasAskedWhileBlocked: Bool { lock.withLock { askedWhileBlocked } }
    var wasAsked: Bool { lock.withLock { asked } }
    var isBlockerRunning: Bool { lock.withLock { blockerRunning } }

    func blockerStarted() {
        lock.withLock { blockerRunning = true }
    }

    func unblock() {
        lock.withLock { blocked = false }
    }

    func ask() -> Bool {
        lock.withLock {
            asked = true
            if blocked { askedWhileBlocked = true }
            return on
        }
    }
}

@Test func aJobWaitingBehindAnotherAsksTheSwitchWhenItRunsAndSkipsItsBodyOnceTheAppIsOff() async {
    let queue = AXQueue()
    let release = DispatchSemaphore(value: 0)
    let appSwitch = QueuedSwitch()
    let blocker = Task {
        await queue.run {
            appSwitch.blockerStarted()
            release.wait()
        }
    }
    for _ in 0 ..< 1_000 where !appSwitch.isBlockerRunning {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(appSwitch.isBlockerRunning)
    let job = Task { await queue.run(while: { appSwitch.ask() }, otherwise: "off") { "read the field" } }
    for _ in 0 ..< 40 where !appSwitch.wasAsked {
        try? await Task.sleep(for: .milliseconds(5))
    }
    appSwitch.isOn = false
    appSwitch.unblock()
    release.signal()
    await blocker.value
    #expect(await job.value == "off")
    #expect(!appSwitch.wasAskedWhileBlocked)
}
