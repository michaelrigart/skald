import Foundation
import Testing
@testable import SkaldCore

private let c = Duration.milliseconds(100)

private func shown(_ reading: String, at time: Duration) -> ScrollSettle<String> {
    var settle = ScrollSettle<String>(ceiling: c)
    _ = settle.scrolled(at: .zero)
    _ = settle.read(reading, at: c)
    _ = settle.read(reading, at: time)
    return settle
}

@Test func aScrollHidesAndAsksForARead() {
    var settle = ScrollSettle<String>(ceiling: c)
    #expect(settle.scrolled(at: .zero) == [.hide, .read(after: c)])
    #expect(settle.isHidden)
}

@Test func equalReadsInsideTheSpanDoNotShow() {
    var settle = ScrollSettle<String>(ceiling: c)
    _ = settle.scrolled(at: .zero)
    #expect(settle.read("a", at: .milliseconds(100)) == [.read(after: c)])
    #expect(settle.read("a", at: .milliseconds(199)) == [.read(after: c)])
    #expect(settle.isHidden)
}

@Test func equalReadsAcrossTheSpanShow() {
    var settle = ScrollSettle<String>(ceiling: c)
    _ = settle.scrolled(at: .zero)
    _ = settle.read("a", at: .milliseconds(100))
    #expect(settle.read("a", at: .milliseconds(200)) == [.show, .read(after: c)])
    #expect(!settle.isHidden)
}

@Test func theSpanCountsFromTheLastScrollEvent() {
    var settle = ScrollSettle<String>(ceiling: c)
    _ = settle.scrolled(at: .zero)
    _ = settle.read("a", at: .milliseconds(100))
    _ = settle.scrolled(at: .milliseconds(150))
    #expect(settle.read("a", at: .milliseconds(250)) == [.read(after: c)])   // the read before the scroll is forgotten
    #expect(settle.read("a", at: .milliseconds(349)) == [.read(after: c)])
    #expect(settle.read("a", at: .milliseconds(350)) == [.show, .read(after: c)])
}

@Test func aScrollForgetsTheReadBeforeIt() {
    var settle = ScrollSettle<String>(ceiling: c)
    _ = settle.scrolled(at: .zero)
    _ = settle.read("a", at: .milliseconds(100))
    _ = settle.scrolled(at: .milliseconds(150))
    #expect(settle.read("a", at: .milliseconds(350)) == [.read(after: c)])
}

@Test func aDifferingReadAfterShowingHidesAgainAndStartsOver() {
    var settle = shown("a", at: .milliseconds(200))
    #expect(settle.read("a", at: .milliseconds(300)) == [.read(after: c)])
    #expect(settle.read("b", at: .milliseconds(400)) == [.hide, .read(after: c)])
    #expect(settle.read("b", at: .milliseconds(500)) == [.read(after: c)])
    #expect(settle.read("b", at: .milliseconds(600)) == [.show, .read(after: c)])
}

@Test func threeAgreeingReadsEndTheConfirming() {
    var settle = shown("a", at: .milliseconds(200))
    #expect(settle.read("a", at: .milliseconds(300)) == [.read(after: c)])
    #expect(settle.read("a", at: .milliseconds(400)) == [.read(after: c)])
    #expect(settle.read("a", at: .milliseconds(500)) == [])
    #expect(settle.read("b", at: .milliseconds(600)) == [])
    #expect(!settle.isHidden)
}

@Test func readsStopAfterTheBound() {
    var settle = ScrollSettle<Int>(ceiling: c)
    _ = settle.scrolled(at: .zero)
    for n in 1..<20 { #expect(settle.read(n, at: c * n) == [.read(after: c)]) }
    #expect(settle.read(20, at: c * 20) == [])
    #expect(settle.isHidden)
}

@Test func anUnmeasuredAppStaysHiddenUntilItIsRedrawn() {
    var settle = ScrollSettle<String>(ceiling: nil)
    #expect(settle.scrolled(at: .zero) == [.hide])
    #expect(settle.read("a", at: .seconds(10)) == [])
    #expect(settle.isHidden)
    settle.redrawn()
    #expect(!settle.isHidden)
}

@Test func aRedrawEndsAPendingSettle() {
    var settle = ScrollSettle<String>(ceiling: c)
    _ = settle.scrolled(at: .zero)
    settle.redrawn()
    #expect(settle.read("a", at: .milliseconds(100)) == [])
    #expect(!settle.isHidden)
}

@Test func theBoundHoldsAcrossRestarts() {
    var settle = ScrollSettle<String>(ceiling: c)
    _ = settle.scrolled(at: .zero)
    let readings = ["a", "a", "b", "b", "b", "c", "c", "c", "d", "d", "d", "e", "e", "e", "f", "f", "f", "g", "g", "h"]
    for (index, reading) in readings.enumerated() {
        let result = settle.read(reading, at: c * (index + 1))
        #expect(result.isEmpty == (index == 19))
    }
    #expect(settle.isHidden)
    #expect(settle.read("h", at: .seconds(10)) == [])
    #expect(settle.read("h", at: .seconds(20)) == [])
    #expect(settle.isHidden)
}

@Test func aReadShowsOnlyWhenItsConfirmingReadsFit() {
    var settle = ScrollSettle<Int>(ceiling: c)
    _ = settle.scrolled(at: .zero)
    for n in 1...17 { _ = settle.read(n, at: c * n) }
    #expect(settle.read(17, at: c * 18) == [.read(after: c)])
    #expect(settle.read(17, at: c * 19) == [.read(after: c)])
    #expect(settle.isHidden)
    #expect(settle.read(17, at: c * 20) == [])
    #expect(settle.isHidden)
}

@Test func theLastShowAtTheSeventeenthReadIsConfirmed() {
    var settle = ScrollSettle<Int>(ceiling: c)
    _ = settle.scrolled(at: .zero)
    for n in 1...16 { _ = settle.read(n, at: c * n) }
    #expect(settle.read(16, at: c * 17) == [.show, .read(after: c)])
    #expect(settle.read(16, at: c * 18) == [.read(after: c)])
    #expect(settle.read(16, at: c * 19) == [.read(after: c)])
    #expect(settle.read(16, at: c * 20) == [])
    #expect(!settle.isHidden)
}

@Test func aDifferingTwentiethReadWhileConfirmingHides() {
    var settle = ScrollSettle<Int>(ceiling: c)
    _ = settle.scrolled(at: .zero)
    for n in 1...16 { _ = settle.read(n, at: c * n) }
    _ = settle.read(16, at: c * 17)
    _ = settle.read(16, at: c * 18)
    _ = settle.read(16, at: c * 19)
    #expect(settle.read(99, at: c * 20) == [.hide])
    #expect(settle.isHidden)
    #expect(settle.read(99, at: c * 30) == [])
}
