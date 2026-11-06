#if DEBUG
import Testing
@testable import SkaldPlatform27

private func same(_ a: Int, _ b: Int) -> Bool { a == b }

@Test func aRememberedMissIsFoundForTheSameElementAndPidOnly() {
    var cache = NegativeLookupCache<Int>()
    cache.remember(7, hash: 7, pid: 10)
    #expect(cache.contains(7, hash: 7, pid: 10, isSame: same))
    #expect(!cache.contains(8, hash: 8, pid: 10, isSame: same))
    #expect(!cache.contains(7, hash: 7, pid: 11, isSame: same))
}

@Test func aHashCollisionIsNotAHitUnlessTheElementsAreTheSame() {
    var cache = NegativeLookupCache<Int>()
    cache.remember(7, hash: 1, pid: 10)
    #expect(!cache.contains(8, hash: 1, pid: 10, isSame: same))
    #expect(cache.contains(7, hash: 1, pid: 10, isSame: same))
}

@Test func aFocusChangeForgetsThatAppsMisses() {
    var cache = NegativeLookupCache<Int>()
    cache.remember(7, hash: 7, pid: 10)
    cache.remember(9, hash: 9, pid: 11)
    cache.clear(pid: 10)
    #expect(!cache.contains(7, hash: 7, pid: 10, isSame: same))
    #expect(cache.contains(9, hash: 9, pid: 11, isSame: same))
}

@Test func theCacheKeepsOnlyTheNewestMissesPerApp() {
    var cache = NegativeLookupCache<Int>(limitPerPid: 2)
    for element in 1 ... 3 { cache.remember(element, hash: element, pid: 10) }
    #expect(!cache.contains(1, hash: 1, pid: 10, isSame: same))
    #expect(cache.contains(2, hash: 2, pid: 10, isSame: same))
    #expect(cache.contains(3, hash: 3, pid: 10, isSame: same))
}

@Test func rememberingTheSameElementTwiceKeepsOneEntry() {
    var cache = NegativeLookupCache<Int>(limitPerPid: 2)
    cache.remember(1, hash: 1, pid: 10, isSame: same)
    cache.remember(1, hash: 1, pid: 10, isSame: same)
    cache.remember(2, hash: 2, pid: 10, isSame: same)
    #expect(cache.contains(1, hash: 1, pid: 10, isSame: same))
}
#endif
