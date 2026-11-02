import Foundation
import Testing
@testable import SkaldPlatform27

private let original = "alpha Hello there ~skald-probe~"

private func reading(
    value: String? = original, role: String = "AXTextArea", formatted: String? = nil
) -> FieldReading {
    var reading = FieldReading(identity: "1-2", role: role, subrole: "", value: value)
    reading.canRead = value != nil
    reading.formatted = formatted.map { AttributedSnapshot(value: NSAttributedString(string: $0)) }
    return reading
}

private func start(before: String? = "Hello ther") -> WriteStart {
    WriteStart(
        original: original,
        before: before.map { AttributedSnapshot(value: NSAttributedString(string: $0)) },
        beforeLocation: 8, beforeLength: 10
    )
}

private func observation() -> FieldObservation {
    FieldObservation(app: "com.example.editor", reading: reading())
}

private func written(before: String? = "Hello ther", after: String? = "Hello ther") -> FieldObservation {
    var observation = observation()
    observation.recordWrite(start(before: before))
    observation.absorb(reading(value: "alpha Hello there ~skald-ok~", formatted: after))
    return observation
}

@Test func writeIsRequestedOnlyOnceAndOnlyAfterTheMarker() {
    var observation = observation()
    #expect(observation.shouldWrite(for: reading()))
    #expect(!observation.shouldWrite(for: reading(value: "alpha Hello there ~skald-pro")))
    observation.recordWrite(start())
    #expect(!observation.shouldWrite(for: reading()))
}

@Test func writeCountsOnceTheValueEndsInTheReplacement() {
    var observation = observation()
    observation.recordWrite(start())
    observation.absorb(reading(value: original))
    #expect(!observation.line.canWrite)
    observation.absorb(reading(value: "alpha Hello there ~skald-ok~", formatted: "Hello ther"))
    #expect(observation.line.canWrite)
    #expect(observation.formatting == nil)
}

@Test func formattingComparesTheTenUnitsBeforeTheMarker() {
    #expect(written().line.formattingKept == true)
    #expect(written(after: "Hello other").line.formattingKept == false)
    #expect(written(before: nil).line.formattingKept == nil)
    #expect(written(after: nil).line.formattingKept == nil)
}

@Test func undoIsExactOnlyWhenTheValueReturnsToTheOriginal() {
    var observation = written()
    observation.absorb(reading(value: original))
    #expect(!observation.line.undoExact)

    observation.recordUndo()
    observation.absorb(reading(value: "alpha Hello there ~skald-ok~"))
    #expect(!observation.line.undoExact)
    observation.absorb(reading(value: original))
    #expect(observation.line.undoExact)
}

@Test func earlierHistorySurvivesOnlyAfterTheSecondUndoRemovesAlpha() {
    var observation = written()
    observation.recordUndo()
    observation.absorb(reading(value: original))
    #expect(observation.line.undoExact)
    #expect(!observation.line.undoEarlierHistory)

    observation.recordUndo()
    observation.absorb(reading(value: original))
    #expect(!observation.line.undoEarlierHistory)
    observation.absorb(reading(value: "Hello there ~skald-probe~"))
    #expect(observation.line.undoEarlierHistory)
}

@Test func anIgnoredWriteNeverCountsAsUndone() {
    var observation = observation()
    observation.recordWrite(start())
    observation.recordUndo()
    observation.recordUndo()
    observation.absorb(reading(value: original))
    observation.absorb(reading(value: "Hello there"))
    #expect(!observation.line.canWrite)
    #expect(!observation.line.undoExact)
    #expect(!observation.line.undoEarlierHistory)
}

@Test func secureFieldsKeepEveryCapabilityFalse() {
    var secure = reading(role: "AXSecureTextField")
    secure.canReadSelection = true
    secure.baseline = BoundsBaseline(length: 9, location: 2, rangeLength: 5, bounds: CGRect(x: 1, y: 1, width: 9, height: 9))
    var observation = FieldObservation(app: "com.example.login", reading: secure)
    observation.absorb(secure)
    #expect(!observation.shouldWrite(for: secure))
    #expect(observation.finishedLine.render().split(separator: "\t").dropFirst(3).prefix(8).allSatisfy { $0 == "false" })
    #expect(observation.baseline == nil)
}

@Test func onlyTrackedNotificationsAfterAKeystrokeAreRecorded() {
    var observation = observation()
    observation.record(notification: "AXValueChanged", afterKeystroke: false)
    observation.record(notification: "AXWindowMoved", afterKeystroke: true)
    observation.record(notification: "AXValueChanged", afterKeystroke: true)
    observation.record(notification: "AXSelectedTextChanged", afterKeystroke: true)
    #expect(observation.finishedLine.notifications == ["AXSelectedTextChanged", "AXValueChanged"])
}

@Test func boundsAreStableOnlyWhenEveryRecheckPasses() {
    var observation = observation()
    #expect(!observation.line.boundsStable)
    observation.recordBoundsCheck(stable: true, baseline: nil)
    #expect(observation.line.boundsStable)
    observation.recordBoundsCheck(stable: false, baseline: nil)
    observation.recordBoundsCheck(stable: true, baseline: nil)
    #expect(!observation.line.boundsStable)
}

private let baseline = BoundsBaseline(
    length: 40, location: 18, rangeLength: 5,
    bounds: CGRect(x: 100, y: 200, width: 30, height: 14), windowOrigin: CGPoint(x: 50, y: 60)
)

@Test func movedWindowMustCarryTheBoundsAlong() {
    let moved = CGPoint(x: 150, y: 90)
    let carried = CGRect(x: 200, y: 230, width: 30, height: 14)
    let stale = CGRect(x: 100, y: 200, width: 30, height: 14)
    let nearlyCarried = CGRect(x: 201.5, y: 228.5, width: 30, height: 14)
    #expect(BoundsComparison.isStable(.windowMoved, old: baseline, bounds: carried, windowOrigin: moved))
    #expect(BoundsComparison.isStable(.windowMoved, old: baseline, bounds: nearlyCarried, windowOrigin: moved))
    #expect(!BoundsComparison.isStable(.windowMoved, old: baseline, bounds: stale, windowOrigin: moved))
    #expect(!BoundsComparison.isStable(.windowMoved, old: baseline, bounds: carried, windowOrigin: nil))
    #expect(!BoundsComparison.isStable(.windowMoved, old: baseline, bounds: nil, windowOrigin: moved))
}

@Test func scrollNeedsOnlyReadableBounds() {
    let scrolled = CGRect(x: 100, y: 150, width: 30, height: 14)
    #expect(BoundsComparison.isStable(.scrolled, old: baseline, bounds: scrolled, windowOrigin: nil))
    #expect(!BoundsComparison.isStable(.scrolled, old: baseline, bounds: nil, windowOrigin: nil))
}
