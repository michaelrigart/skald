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
    resolution.search = SearchOutcome(found: false, role: nil, subrole: nil, visited: 3000, elapsedMs: 150)
    #expect(!resolution.resolved)
    #expect(resolution.summary.hasSuffix("search found false role - subrole -, visited 3000, 150 ms"))
    resolution.search = SearchOutcome(found: true, role: "AXTextArea", subrole: nil, visited: 12, elapsedMs: 4)
    #expect(resolution.resolved)
    #expect(resolution.summary.hasSuffix("search found true role AXTextArea subrole -, visited 12, 4 ms"))
}
