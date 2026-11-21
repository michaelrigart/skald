import CoreGraphics
import Foundation
import SkaldCore
import Testing
@testable import Skald

@MainActor struct ScrollLagTests {
    @Test func onlyMeasuredAppsHaveACeiling() {
        #expect(ScrollLag.ceiling(for: "com.example.unmeasured") == nil)
        #expect(ScrollLag.ceilings.values.allSatisfy { $0 >= .milliseconds(50) && $0 <= .seconds(5) })
    }
}

/// The controller's scroll path with a hand-driven clock: every sleep waits until the test releases it.
@MainActor private final class Harness {
    let first = [CGRect(x: 10, y: 10, width: 40, height: 2)]
    let second = [CGRect(x: 10, y: 30, width: 40, height: 2)]

    var clock: Duration = .zero
    var sleepers: [(for: Duration, resume: CheckedContinuation<Void, Never>)] = []
    var layoutCalls = 0
    var reading: [CGRect]
    /// Set to hold the next layout read until the test resumes it.
    var holdLayout = false
    var held: CheckedContinuation<Void, Never>?
    var hides = 0
    var shown: [[CGRect]] = []
    private(set) var settler: ScrollSettler<[CGRect]>!

    init(ceiling: Duration?) {
        reading = first
        settler = ScrollSettler(
            ceiling: ceiling,
            sleep: { [unowned self] duration in
                await withCheckedContinuation { sleepers.append((duration, $0)) }
            },
            now: { [unowned self] in clock },
            layout: { [unowned self] in
                layoutCalls += 1
                let snapshot = reading
                if holdLayout {
                    holdLayout = false
                    await withCheckedContinuation { held = $0 }
                }
                return snapshot
            },
            rects: { $0 },
            hide: { [unowned self] in hides += 1 },
            show: { [unowned self] in shown.append($0) }
        )
    }

    func quiet() async {
        for _ in 0..<50 { await Task.yield() }
    }

    /// Lets the sleep at `index` end, `duration` later on the clock.
    func release(_ index: Int = 0) async {
        let sleeper = sleepers.remove(at: index)
        clock += sleeper.for
        sleeper.resume.resume()
        await quiet()
    }
}

@MainActor struct ScrollSettlerTests {
    private let ceiling: Duration = .milliseconds(100)

    @Test func aScrollHidesAndTwoAgreeingReadsBringTheUnderlinesBack() async {
        let harness = Harness(ceiling: ceiling)
        harness.settler.scrolled()
        await harness.quiet()
        #expect(harness.hides == 1)
        #expect(harness.settler.isHidden)
        #expect(harness.sleepers.map(\.for) == [ceiling])

        await harness.release()
        #expect(harness.shown.isEmpty)
        await harness.release()
        #expect(harness.shown == [harness.first])
        #expect(!harness.settler.isHidden)

        for _ in 0..<ScrollSettle<[CGRect]>.confirmingReads { await harness.release() }
        #expect(harness.sleepers.isEmpty)
        #expect(harness.hides == 1)
        #expect(harness.layoutCalls == 2 + ScrollSettle<[CGRect]>.confirmingReads)
    }

    @Test func aReadStartedBeforeANewerScrollIsDroppedNotFed() async {
        let harness = Harness(ceiling: ceiling)
        harness.settler.scrolled()
        await harness.quiet()
        harness.holdLayout = true
        await harness.release()
        #expect(harness.layoutCalls == 1)

        harness.settler.scrolled()
        await harness.quiet()
        harness.held?.resume()
        await harness.quiet()
        // Fed to the settle, the old read would have asked for a further read of its own.
        #expect(harness.sleepers.count == 1)
        #expect(harness.hides == 2)
    }

    @Test func aNewScrollCancelsASleepingRead() async {
        let harness = Harness(ceiling: ceiling)
        harness.settler.scrolled()
        await harness.quiet()
        harness.settler.scrolled()
        await harness.quiet()
        #expect(harness.sleepers.count == 2)

        await harness.release(0)
        #expect(harness.layoutCalls == 0)
        await harness.release()
        #expect(harness.layoutCalls == 1)
    }

    @Test func aTextOrCaretChangeBringsThemBackAndCancelsTheReads() async {
        let harness = Harness(ceiling: ceiling)
        harness.settler.scrolled()
        await harness.quiet()
        harness.settler.redrawn()
        #expect(!harness.settler.isHidden)
        await harness.release()
        #expect(harness.layoutCalls == 0)
        #expect(harness.sleepers.isEmpty)
    }

    @Test func anUnmeasuredAppStaysHiddenWithNoTimerUntilAnEdit() async {
        let harness = Harness(ceiling: nil)
        harness.settler.scrolled()
        await harness.quiet()
        #expect(harness.hides == 1)
        #expect(harness.settler.isHidden)
        #expect(harness.sleepers.isEmpty)
        #expect(harness.layoutCalls == 0)
        harness.settler.redrawn()
        #expect(!harness.settler.isHidden)
    }

    @Test func aReadThatDiffersAfterTheShowHidesAgainAndKeepsReading() async {
        let harness = Harness(ceiling: ceiling)
        harness.settler.scrolled()
        await harness.quiet()
        await harness.release()
        await harness.release()
        #expect(harness.shown.count == 1)

        harness.reading = harness.second
        await harness.release()
        #expect(harness.hides == 2)
        #expect(harness.settler.isHidden)
        #expect(harness.sleepers.count == 1)
    }

    @Test func readsStopAfterTheBoundAndNothingIsLeftRunning() async {
        let harness = Harness(ceiling: ceiling)
        harness.settler.scrolled()
        await harness.quiet()
        for round in 0..<ScrollSettle<[CGRect]>.maxReads {
            harness.reading = [CGRect(x: CGFloat(round), y: 0, width: 40, height: 2)]
            await harness.release()
        }
        #expect(harness.layoutCalls == ScrollSettle<[CGRect]>.maxReads)
        #expect(harness.sleepers.isEmpty)
        #expect(harness.settler.isHidden)
        #expect(harness.shown.isEmpty)
    }

    @Test func theDrawEpochMovesOnAScrollARedrawAndAShowButNotOnAReadThatDoesNotShow() async {
        let harness = Harness(ceiling: ceiling)
        var epoch = harness.settler.drawEpoch
        harness.settler.scrolled()
        #expect(harness.settler.drawEpoch != epoch)
        epoch = harness.settler.drawEpoch
        await harness.quiet()
        await harness.release()
        #expect(harness.settler.drawEpoch == epoch)
        await harness.release()
        #expect(harness.shown.count == 1)
        #expect(harness.settler.drawEpoch != epoch)
        epoch = harness.settler.drawEpoch
        await harness.release()
        #expect(harness.settler.drawEpoch == epoch)
        harness.settler.redrawn()
        #expect(harness.settler.drawEpoch != epoch)
    }

    /// A pass that began before a scroll, a redraw or a show must not draw its marks after it, and nor may one
    /// that ends while the underlines are hidden.
    @Test func aPassDrawsItsMarksOnlyWhenNothingChangedAndNothingIsHidden() async {
        let harness = Harness(ceiling: ceiling)
        var began = harness.settler.drawEpoch
        #expect(harness.settler.mayDrawMarks(since: began))

        harness.settler.scrolled()
        #expect(!harness.settler.mayDrawMarks(since: harness.settler.drawEpoch))
        await harness.quiet()
        await harness.release()
        began = harness.settler.drawEpoch
        await harness.release()
        // The show drew its own layout; the pass that began before it is stale, one that began after is not.
        #expect(!harness.settler.mayDrawMarks(since: began))
        #expect(harness.settler.mayDrawMarks(since: harness.settler.drawEpoch))

        began = harness.settler.drawEpoch
        harness.settler.redrawn()
        #expect(!harness.settler.mayDrawMarks(since: began))
        #expect(harness.settler.mayDrawMarks(since: harness.settler.drawEpoch))
    }
}
