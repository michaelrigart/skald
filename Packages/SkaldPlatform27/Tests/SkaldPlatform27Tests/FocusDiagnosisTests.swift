import Testing
@testable import SkaldPlatform27

@Test func aFocusDiagnosisNamesTheErrorCodeAndTheRoleOnly() {
    let found = FocusDiagnosis(found: true, role: "AXTextArea", errorCode: 0)
    #expect(found.summary(afterMs: 1000) == "after 1000 ms: element found true role AXTextArea, focused query AXError 0")
    let missing = FocusDiagnosis(found: false, role: nil, errorCode: -25212)
    #expect(missing.summary(afterMs: 0) == "after 0 ms: element found false role -, focused query AXError -25212")
}

@Test func anEnableResultNamesTheAttributeAndTheErrorCode() {
    #expect(EnableResult(attribute: "AXManualAccessibility", code: -25205).summary == "AXManualAccessibility AXError -25205")
}

@Test func enablingNativeAppsSetsNothing() {
    #expect(AppAccessibilityMode.native.attributesSet.isEmpty)
    #expect(AppAccessibilityMode.chromium.attributesSet == ["AXManualAccessibility"])
    #expect(AppAccessibilityMode.firefox.attributesSet == ["AXEnhancedUserInterface"])
}

@Test func theFocusRetriesRunUntilTenSeconds() {
    #expect(FocusDiagnosis.retryOffsetsMs == [0, 1000, 3000, 6000, 10000])
}

@Test func aLateFocusStartsASessionOnlyWhileTheAppIsFrontmostWithTheSameFocus() {
    #expect(FocusDiagnosis.startsSession(found: true, frontmost: true, generationUnchanged: true))
    #expect(!FocusDiagnosis.startsSession(found: false, frontmost: true, generationUnchanged: true))
    #expect(!FocusDiagnosis.startsSession(found: true, frontmost: false, generationUnchanged: true))
    #expect(!FocusDiagnosis.startsSession(found: true, frontmost: true, generationUnchanged: false))
}

@Test func aQueryThatCannotCompleteOrHitsTheTimeoutIsAskedAgainWithMoreTime() {
    #expect(FocusDiagnosis.needsSlowQuery(errorCode: -25204, elapsedMs: 3))
    #expect(FocusDiagnosis.needsSlowQuery(errorCode: -25212, elapsedMs: 250))
    #expect(!FocusDiagnosis.needsSlowQuery(errorCode: -25212, elapsedMs: 249))
    #expect(!FocusDiagnosis.needsSlowQuery(errorCode: 0, elapsedMs: 10))
    #expect(SlowFocusQuery.timeout == 1)
}

@Test func theSlowQueryIsReportedInNumbersAndBooleansOnly() {
    let diagnosis = FocusDiagnosis(
        found: false, role: nil, errorCode: -25204, elapsedMs: 251,
        slow: SlowFocusQuery(answered: true, found: true, errorCode: 0, elapsedMs: 640)
    )
    #expect(diagnosis.summary(afterMs: 3000) == "after 3000 ms: element found false role -, focused query AXError -25204 in 251 ms; "
        + "1 s timeout query answered true, element found true, AXError 0, 640 ms")
}
