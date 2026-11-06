import Testing
@testable import SkaldPlatform27

@Test func aKeystrokeStaysTheTriggerWhenANotificationPushesItsEvaluationBack() {
    #expect(EvaluationTrigger.merged(pending: nil, incoming: .notification) == .notification)
    #expect(EvaluationTrigger.merged(pending: .keystroke, incoming: .notification) == .keystroke)
    #expect(EvaluationTrigger.merged(pending: .keystroke, incoming: .quietPeriod) == .keystroke)
    #expect(EvaluationTrigger.merged(pending: .notification, incoming: .keystroke) == .keystroke)
    #expect(EvaluationTrigger.merged(pending: .notification, incoming: .notification) == .notification)
}

@Test func theDiagnosisNamesTheFirstStepThatFailed() {
    typealias Outcome = EvaluationDiagnosis.Outcome
    #expect(Outcome.classify(focusedFound: false, resolvedFound: false, valueRead: false) == .noFocusedElement)
    #expect(Outcome.classify(focusedFound: false, resolvedFound: true, valueRead: true) == .noFocusedElement)
    #expect(Outcome.classify(focusedFound: true, resolvedFound: false, valueRead: false) == .resolutionFailed)
    #expect(Outcome.classify(focusedFound: true, resolvedFound: true, valueRead: false) == .valueNil)
    #expect(Outcome.classify(focusedFound: true, resolvedFound: true, valueRead: true) == .valueRead)
}

@Test func theDiagnosisLogsNumbersBooleansAndRolesOnly() {
    let diagnosis = EvaluationDiagnosis(
        measureReturnedNil: true, sessionCurrent: true, outcome: .noFocusedElement, focusedQueryError: -25204,
        resolvedRole: nil, sameAsFocused: nil, resolvedMarkers: .unavailable, focusedMarkers: .unavailable
    )
    #expect(diagnosis.summary == "measure returned nil true, session current true; now no focused element, focused query AXError -25204, "
        + "resolved role -, same as focused -; text markers on resolved: initialises false; on focused: initialises false")
    let found = EvaluationDiagnosis(
        measureReturnedNil: false, sessionCurrent: false, outcome: .valueRead, focusedQueryError: 0,
        resolvedRole: "AXWebArea", sameAsFocused: true,
        resolvedMarkers: MarkerFieldState(initialises: true, textLength: 120, caretLocation: 34, caretLength: 0),
        focusedMarkers: MarkerFieldState(initialises: true, textLength: nil, caretLocation: nil, caretLength: nil)
    )
    #expect(found.summary == "measure returned nil false, session current false; now value read, focused query AXError 0, "
        + "resolved role AXWebArea, same as focused true; text markers on resolved: initialises true, text length 120, caret 34,0; "
        + "on focused: initialises true, text length -, caret none")
}
