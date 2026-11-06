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

@Test func aWrittenFieldIsRememberedByItsIdentityOnly() {
    var fields = WrittenFields()
    #expect(fields.prior(for: "1-2") == nil)
    fields.record(PriorWrite(start: pasted(), undoPresses: 0), for: "1-2")
    #expect(fields.prior(for: "1-2")?.undoPresses == 0)
    #expect(fields.prior(for: "1-3") == nil)
    fields.record(PriorWrite(start: pasted(), undoPresses: 1), for: "1-2")
    #expect(fields.prior(for: "1-2")?.undoPresses == 1)
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
