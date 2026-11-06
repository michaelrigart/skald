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
