#if DEBUG
import Foundation
import Testing
@testable import SkaldPlatform27

private let original = "alpha Hello there ~skald-probe~"

private func markerReading(identity: String = "1-2") -> FieldReading {
    var reading = FieldReading(identity: identity, role: "AXTextArea", subrole: "", value: original)
    reading.canRead = true
    return reading
}

private func pasted() -> WriteStart {
    var start = WriteStart(original: original, before: nil, beforeLocation: 8, beforeLength: 10)
    start.method = .paste
    return start
}

@Test func aWrittenFieldIsRememberedByItsIdentity() {
    var fields = WrittenFields()
    #expect(fields.prior(identity: "1-2", pid: 1, value: nil) == nil)
    fields.record(PriorWrite(start: pasted(), undoPresses: 0), for: "1-2", pid: 1)
    #expect(fields.prior(identity: "1-2", pid: 1, value: nil)?.prior.undoPresses == 0)
    #expect(fields.prior(identity: "1-3", pid: 1, value: nil) == nil)
    fields.record(PriorWrite(start: pasted(), undoPresses: 1), for: "1-2", pid: 1)
    #expect(fields.prior(identity: "1-2", pid: 1, value: nil)?.prior.undoPresses == 1)
}

@Test func aFieldWithANewHashIsStillRecognisedByTheValueBeforeTheWriteInTheSameApp() {
    var fields = WrittenFields()
    fields.record(PriorWrite(start: pasted(), undoPresses: 1), for: "1-2", pid: 1)
    let rehashed = fields.prior(identity: "1-9", pid: 1, value: original)
    #expect(rehashed?.identity == "1-2")
    #expect(rehashed?.prior.undoPresses == 1)
    #expect(fields.prior(identity: "2-9", pid: 2, value: original) == nil)
    #expect(fields.prior(identity: "1-9", pid: 1, value: "other text ~skald-probe~") == nil)
}

@Test func aLaterSessionOnAWrittenFieldNeverWritesButStillMeasuresUndo() {
    var first = FieldObservation(app: "org.mozilla.zen", reading: markerReading())
    first.recordWrite(pasted())
    first.recordUndo()
    let prior = first.priorWrite
    #expect(prior?.undoPresses == 1)

    var later = FieldObservation(app: "org.mozilla.zen", reading: markerReading())
    #expect(later.shouldWrite(for: markerReading()))
    later.adopt(prior!)
    #expect(!later.shouldWrite(for: markerReading()))
    #expect(later.hasWrite)
    #expect(later.writeKind == .ranges)
    #expect(later.finishedLine.writeMethod == nil)
    later.recordUndo()
    #expect(later.undoPresses == 2)
    #expect(later.writeCheck(original)?.contains("is original true") == true)
}

@Test func aSessionWithoutAWriteHasNothingToRemember() {
    #expect(FieldObservation(app: "org.mozilla.zen", reading: markerReading()).priorWrite == nil)
}
#endif
