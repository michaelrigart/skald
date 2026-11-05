import Testing
@testable import SkaldPlatform27

private struct Tree {
    var role: String?
    var focused = false
    var settable = false
    var tag = ""
    var kids: [Tree] = []

    var info: SearchNodeInfo { SearchNodeInfo(role: role, focused: focused, selectionSettable: settable) }
}

private func search(
    _ root: Tree, limits: SearchLimits = SearchLimits(), clock: @escaping () -> Int = { 0 }
) -> SearchResult<Tree> {
    FocusedDescendantSearch.find(in: root, limits: limits, elapsedMs: clock, info: { $0.info }, children: { $0.kids })
}

@Test func aFocusedTextAreaIsPreferredOverAnEarlierShallowerFocusedGroup() {
    let tree = Tree(role: "AXWebArea", kids: [
        Tree(role: "AXGroup", focused: true, tag: "group", kids: [Tree(role: "AXTextArea", focused: true, tag: "area")]),
        Tree(role: "AXLink"),
    ])
    #expect(search(tree).found?.tag == "area")
}

@Test func anElementWithASettableSelectionIsPreferredWhateverItsRole() {
    let tree = Tree(role: "AXWebArea", kids: [
        Tree(role: "AXGroup", focused: true, tag: "plain"),
        Tree(role: "AXGroup", focused: true, settable: true, tag: "editable"),
        Tree(role: "AXTextField", focused: true, tag: "field"),
    ])
    #expect(search(tree).found?.tag == "editable")
}

@Test func withoutAPreferredElementTheDeepestFocusedOneWinsAndTiesTakeTheFirst() {
    let tree = Tree(role: "AXWebArea", kids: [
        Tree(role: "AXGroup", focused: true, tag: "shallow"),
        Tree(role: "AXGroup", tag: "branch", kids: [
            Tree(role: "AXGroup", focused: true, tag: "deep first", kids: [Tree(role: "AXStaticText", focused: true, tag: "deepest")]),
            Tree(role: "AXGroup", focused: true, tag: "deep second"),
        ]),
    ])
    #expect(search(tree).found?.tag == "deepest")
    let ties = Tree(role: "AXWebArea", kids: [
        Tree(role: "AXGroup", focused: true, tag: "one"), Tree(role: "AXGroup", focused: true, tag: "two"),
    ])
    #expect(search(ties).found?.tag == "one")
}

@Test func nothingFocusedFindsNothingAndCountsEveryVisit() {
    let tree = Tree(role: "AXWebArea", kids: [Tree(role: "AXGroup", kids: [Tree(role: "AXLink")]), Tree(role: "AXLink")])
    let result = search(tree)
    #expect(result.found == nil)
    #expect(result.visited == 3)
}

@Test func theWebAreaItselfIsNeverTheResult() {
    #expect(search(Tree(role: "AXWebArea", focused: true, settable: true)).found == nil)
}

@Test func theSearchStopsAtTheVisitLimit() {
    let wide = Tree(role: "AXWebArea", kids: (0 ..< 50).map { _ in Tree(role: "AXLink") } + [Tree(role: "AXTextArea", focused: true, tag: "late")])
    let limited = search(wide, limits: SearchLimits(maxVisited: 10, maxDepth: 40, maxMs: 150))
    #expect(limited.found == nil)
    #expect(limited.visited == 10)
    #expect(search(wide).found?.tag == "late")
}

@Test func theSearchDoesNotGoBelowTheDepthLimit() {
    var chain = Tree(role: "AXTextArea", focused: true, tag: "bottom")
    for _ in 0 ..< 4 { chain = Tree(role: "AXGroup", kids: [chain]) }
    let tree = Tree(role: "AXWebArea", kids: [chain])
    #expect(search(tree, limits: SearchLimits(maxVisited: 3000, maxDepth: 5, maxMs: 150)).found?.tag == "bottom")
    let cut = search(tree, limits: SearchLimits(maxVisited: 3000, maxDepth: 4, maxMs: 150))
    #expect(cut.found == nil)
    #expect(cut.visited == 4)
}

@Test func theSearchStopsWhenTheTimeIsUp() {
    let wide = Tree(role: "AXWebArea", kids: (0 ..< 50).map { _ in Tree(role: "AXLink") } + [Tree(role: "AXTextArea", focused: true, tag: "late")])
    var now = 0
    let result = search(wide, clock: {
        now += 10
        return now
    })
    #expect(result.found == nil)
    #expect(result.visited < 50)
    #expect(result.elapsedMs > 150)
}

@Test func theDefaultLimitsAreTheAgreedOnes() {
    let limits = SearchLimits()
    #expect(limits.maxVisited == 3000)
    #expect(limits.maxDepth == 40)
    #expect(limits.maxMs == 150)
}
