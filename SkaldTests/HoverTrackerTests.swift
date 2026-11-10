import CoreGraphics
import Foundation
import Testing
@testable import Skald

struct HoverTrackerTests {
    private let first = UUID()
    private let second = UUID()
    private var targets: [HoverTracker.Target] {
        [
            .init(id: first, rect: CGRect(x: 100, y: 100, width: 60, height: 18)),
            .init(id: second, rect: CGRect(x: 200, y: 100, width: 40, height: 18)),
        ]
    }

    @Test func enteringAWordStartsTheWaitForThatWord() {
        var tracker = HoverTracker()
        #expect(tracker.pointer(at: CGPoint(x: 120, y: 110), over: targets) == .entered(first))
    }

    /// The 300 ms wait runs from entering the word; moving within it must not restart the wait.
    @Test func movingWithinTheSameWordChangesNothing() {
        var tracker = HoverTracker()
        _ = tracker.pointer(at: CGPoint(x: 120, y: 110), over: targets)
        #expect(tracker.pointer(at: CGPoint(x: 150, y: 112), over: targets) == .unchanged)
    }

    @Test func movingStraightToAnotherWordStartsTheWaitForThatOne() {
        var tracker = HoverTracker()
        _ = tracker.pointer(at: CGPoint(x: 120, y: 110), over: targets)
        #expect(tracker.pointer(at: CGPoint(x: 210, y: 110), over: targets) == .entered(second))
    }

    @Test func leavingEveryWordCancelsTheWait() {
        var tracker = HoverTracker()
        _ = tracker.pointer(at: CGPoint(x: 120, y: 110), over: targets)
        #expect(tracker.pointer(at: CGPoint(x: 120, y: 300), over: targets) == .left)
        #expect(tracker.pointer(at: CGPoint(x: 120, y: 310), over: targets) == .unchanged)
    }

    /// Catches a word that vanished from the targets (scrolled away, fixed) still counting as hovered.
    @Test func aWordThatIsNoLongerATargetIsLeft() {
        var tracker = HoverTracker()
        _ = tracker.pointer(at: CGPoint(x: 120, y: 110), over: targets)
        #expect(tracker.pointer(at: CGPoint(x: 120, y: 110), over: []) == .left)
    }

    /// I1: the card covers a word on the next line; the pointer on the card's Accept is not on that word.
    @Test func aWordUnderTheOpenCardCannotBeHovered() {
        var tracker = HoverTracker()
        let card = CGRect(x: 180, y: 0, width: 320, height: 120)
        #expect(tracker.pointer(at: CGPoint(x: 210, y: 110), over: targets, covered: card) == .unchanged)
        #expect(tracker.current == nil)
    }

    @Test func leavingTheCardOntoAWordItDoesNotCoverEntersIt() {
        var tracker = HoverTracker()
        let card = CGRect(x: 180, y: 0, width: 320, height: 120)
        _ = tracker.pointer(at: CGPoint(x: 210, y: 110), over: targets, covered: card)
        #expect(tracker.pointer(at: CGPoint(x: 120, y: 110), over: targets, covered: card) == .entered(first))
    }

    /// M2: from x 99 to 98.5 the pointer stays within the word's slack, so the card must stay too; a close
    /// area without the slack would close it while the tracker still saw the word, and it never reopened.
    @Test func theCardStaysOpenWithinTheSameSlackTheWordIsEnteredWith() {
        var tracker = HoverTracker()
        let word = CGRect(x: 100, y: 100, width: 60, height: 18)
        let card = CGRect(x: 100, y: -24, width: 320, height: 120)
        #expect(tracker.pointer(at: CGPoint(x: 99, y: 110), over: targets) == .entered(first))
        #expect(HoverTracker.keepsCard(at: CGPoint(x: 99, y: 110), anchor: word, card: card))
        #expect(tracker.pointer(at: CGPoint(x: 98.5, y: 110), over: targets) == .unchanged)
        #expect(HoverTracker.keepsCard(at: CGPoint(x: 98.5, y: 110), anchor: word, card: card))
        #expect(!HoverTracker.keepsCard(at: CGPoint(x: 97.5, y: 110), anchor: word, card: card))
    }

    @Test func thePointerCountsUpToTwoPointsBelowTheWordWhereTheUnderlineIs() {
        var tracker = HoverTracker()
        #expect(tracker.pointer(at: CGPoint(x: 120, y: 98.5), over: targets) == .entered(first))
    }
}
