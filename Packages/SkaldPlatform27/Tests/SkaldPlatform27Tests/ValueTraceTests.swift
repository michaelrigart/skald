import Testing
@testable import SkaldPlatform27

private func sample(_ n: Int) -> ValueTrace.Sample {
    ValueTrace.Sample(valueLength: n, characterCount: n + 1, selectionLocation: n - 1)
}

private func reports(_ trace: inout ValueTrace, _ sample: ValueTrace.Sample?, marker: Bool = false) -> Bool {
    trace.observe(sample, containsMarker: marker)
}

@Test func theTraceReportsOnTheFifthCountedEvaluationWithoutAMarker() {
    var trace = ValueTrace()
    for n in 1 ... 4 {
        #expect(!reports(&trace, sample(n)))
    }
    #expect(!reports(&trace, nil))
    #expect(reports(&trace, sample(5)))
    #expect(!reports(&trace, sample(6)))
    #expect(trace.summary(keystrokes: 9) == "keystrokes 9, value lengths 1,2,3,4,5, characters 2,3,4,5,6, selection locations 0,1,2,3,4")
}

@Test func aMarkerInAnyReadingEndsTheTrace() {
    var trace = ValueTrace()
    #expect(!reports(&trace, sample(1)))
    #expect(!reports(&trace, nil, marker: true))
    for n in 2 ... 8 {
        #expect(!reports(&trace, sample(n)))
    }
}

@Test func missingNumbersShowAsDashes() {
    var trace = ValueTrace()
    for _ in 1 ... 5 {
        _ = reports(&trace, ValueTrace.Sample(valueLength: nil, characterCount: nil, selectionLocation: nil))
    }
    #expect(trace.summary(keystrokes: 5) == "keystrokes 5, value lengths -,-,-,-,-, characters -,-,-,-,-, selection locations -,-,-,-,-")
}
