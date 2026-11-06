#if DEBUG
import Testing
@testable import SkaldPlatform27

@Test func onlyAWebAreaIsResolvedToItsEditableElement() {
    #expect(AXElement.needsEditableResolution(role: "AXWebArea"))
    #expect(!AXElement.needsEditableResolution(role: "AXTextArea"))
    #expect(!AXElement.needsEditableResolution(role: "AXTextField"))
    #expect(!AXElement.needsEditableResolution(role: nil))
}

@Test func aResolutionIsResolvedOnlyWithAnEditableAncestor() {
    let found = EditableResolution(markerRangePresent: true, leafRole: "AXStaticText", ancestorRole: "AXTextArea", ancestorSubrole: nil)
    let noAncestor = EditableResolution(markerRangePresent: true, leafRole: "AXStaticText")
    let noRange = EditableResolution(markerRangePresent: false)
    #expect(found.resolved)
    #expect(!noAncestor.resolved)
    #expect(!noRange.resolved)
}

@Test func theSummaryNamesRolesAndPresenceOnly() {
    let found = EditableResolution(markerRangePresent: true, leafRole: "AXStaticText", ancestorRole: "AXTextArea", ancestorSubrole: "AXFoo")
    #expect(found.summary == "marker range present true, start marker present false, leaf AXStaticText, editable ancestor AXTextArea AXFoo")
    #expect(EditableResolution(markerRangePresent: false).summary
        == "marker range present false, start marker present false, leaf -, editable ancestor -")
    let noLeaf = EditableResolution(markerRangePresent: true, startMarkerPresent: true)
    #expect(noLeaf.summary == "marker range present true, start marker present true, leaf -, editable ancestor -")
}

@Test func eachAppLogsTheFirstResolutionAndTheFirstFailureOnce() {
    let log = WebAreaLog()
    #expect(log.isFirst(pid: 10, resolved: true))
    #expect(!log.isFirst(pid: 10, resolved: true))
    #expect(log.isFirst(pid: 10, resolved: false))
    #expect(!log.isFirst(pid: 10, resolved: false))
    #expect(log.isFirst(pid: 11, resolved: true))
}

@Test func aNewFieldSessionLogsTheFailureAgainButNotTheSuccess() {
    let log = WebAreaLog()
    #expect(log.isFirst(pid: 10, resolved: false))
    #expect(log.isFirst(pid: 10, resolved: true))
    log.endSession(pid: 10)
    #expect(log.isFirst(pid: 10, resolved: false))
    #expect(!log.isFirst(pid: 10, resolved: true))
    #expect(log.isFirst(pid: 11, resolved: false))
}

@Test func aSearchOutcomeCountsAsResolvedAndShowsInTheSummary() {
    var resolution = EditableResolution(markerRangePresent: false)
    resolution.search = SearchOutcome(found: false, preferred: false, role: nil, subrole: nil, visited: 3000, elapsedMs: 150)
    #expect(!resolution.resolved)
    #expect(resolution.summary.hasSuffix("search found false preferred false role - subrole -, visited 3000, 150 ms"))
    resolution.search = SearchOutcome(found: true, preferred: true, role: "AXTextArea", subrole: nil, visited: 12, elapsedMs: 4)
    #expect(resolution.resolved)
    #expect(resolution.summary.hasSuffix("search found true preferred true role AXTextArea subrole -, visited 12, 4 ms"))
}

@Test func aPasteIsAllowedOnlyOnAnElementThatIsNotAMereDeepestFocusedGuess() {
    #expect(EditableResolution.allowsPaste(nil))
    #expect(EditableResolution.allowsPaste(EditableResolution(markerRangePresent: true, leafRole: "AXStaticText", ancestorRole: "AXTextArea")))
    var preferred = EditableResolution(markerRangePresent: false)
    preferred.search = SearchOutcome(found: true, preferred: true, role: "AXTextArea", subrole: nil, visited: 5, elapsedMs: 1)
    #expect(EditableResolution.allowsPaste(preferred))
    var deepest = EditableResolution(markerRangePresent: false)
    deepest.search = SearchOutcome(found: true, preferred: false, role: "AXGroup", subrole: nil, visited: 5, elapsedMs: 1)
    #expect(!EditableResolution.allowsPaste(deepest))
    var none = EditableResolution(markerRangePresent: false)
    none.search = SearchOutcome(found: false, preferred: false, role: nil, subrole: nil, visited: 5, elapsedMs: 1)
    #expect(!EditableResolution.allowsPaste(none))
}

@Test func theTextMarkerReportHasOnlyBooleansAndNumbers() {
    let full = TextMarkerReport(
        elementRangePresent: true, elementTextLength: 412, selectedRangePresent: true,
        startIndex: 17, endIndex: 17, selectedLength: 0
    )
    #expect(full.summary == "element range present true, element text length 412, selected range present true, "
        + "start index 17, end index 17, selected length 0")
    let empty = TextMarkerReport(elementRangePresent: false, selectedRangePresent: false)
    #expect(empty.summary == "element range present false, element text length -, selected range present false, "
        + "start index -, end index -, selected length -")
}

@Test func theMarkerReportIsWantedOnceUntilTheSessionEnds() {
    let log = WebAreaLog()
    #expect(log.shouldReportMarkers(pid: 10))
    #expect(!log.shouldReportMarkers(pid: 10))
    #expect(log.shouldReportMarkers(pid: 11))
    log.endSession(pid: 10)
    #expect(log.shouldReportMarkers(pid: 10))
}

@Test func aMarkerFieldIsPastedOnlyWhenNotAMereDeepestFocusedGuess() {
    func resolution(found: Bool, preferred: Bool) -> EditableResolution {
        var resolution = EditableResolution(markerRangePresent: true)
        resolution.search = SearchOutcome(found: found, preferred: preferred, role: nil, subrole: nil, visited: 5, elapsedMs: 1)
        return resolution
    }
    #expect(EditableResolution.allowsPaste(nil, kind: .textMarkers))
    #expect(EditableResolution.allowsPaste(resolution(found: true, preferred: true), kind: .textMarkers))
    #expect(!EditableResolution.allowsPaste(resolution(found: true, preferred: false), kind: .textMarkers))
    #expect(EditableResolution.allowsPaste(resolution(found: false, preferred: false), kind: .textMarkers))
    #expect(!EditableResolution.allowsPaste(resolution(found: false, preferred: false), kind: .ranges))
    #expect(!EditableResolution.allowsPaste(resolution(found: true, preferred: false), kind: .ranges))
}

@Test func theEditableAncestorDiagnosisIsNamedForTheLog() {
    #expect(TextMarkerField.describeEditableAncestor(true) == "true")
    #expect(TextMarkerField.describeEditableAncestor(false) == "false")
    #expect(TextMarkerField.describeEditableAncestor(nil) == "unsupported")
}
#endif
