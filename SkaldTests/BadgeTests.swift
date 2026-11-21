import CoreGraphics
import SkaldCore
import Testing
@testable import Skald

struct BadgeTests {
    @Test func theBadgeKeepsItsContentWhileTheSameFieldIsRechecked() {
        #expect(BadgeContent.next(current: nil, issues: 3, checked: true, sameField: false, paused: false) == .count(3))
        #expect(BadgeContent.next(current: .count(3), issues: 0, checked: true, sameField: true, paused: false) == .tick)
        #expect(BadgeContent.next(current: .count(3), issues: 0, checked: false, sameField: true, paused: false) == .count(3))
        #expect(BadgeContent.next(current: .tick, issues: 0, checked: false, sameField: true, paused: false) == .tick)
        #expect(BadgeContent.next(current: .count(3), issues: 0, checked: false, sameField: false, paused: false) == nil)
        #expect(BadgeContent.next(current: .count(3), issues: 0, checked: false, sameField: true, paused: true) == nil)
        #expect(BadgeContent.next(current: nil, issues: 0, checked: false, sameField: true, paused: false) == nil)
    }

    @Test func aHeldCountKeepsItsLabelAndANewResultBringsItsOwn() {
        let issues = (0..<3).map { _ in issue(in: "teh cat", revised: "the cat", source: .spelling) }
        let shown = BadgeState.next(current: nil, issues: issues, checked: true, sameField: false, paused: false)
        #expect(shown == BadgeState(content: .count(3), label: "3 suggestions: 3 spelling"))
        #expect(BadgeState.next(current: shown, issues: [], checked: false, sameField: true, paused: false) == shown)
        #expect(BadgeState.next(current: shown, issues: [], checked: true, sameField: true, paused: false)
            == BadgeState(content: .tick, label: "No suggestions"))
        #expect(BadgeState.next(current: shown, issues: [], checked: false, sameField: true, paused: true) == nil)
        #expect(BadgeState.next(current: shown, issues: [], checked: false, sameField: false, paused: false) == nil)
    }

    @Test func theDottedLineIsTwoPointSquaresEveryFourPointsWithAtLeastOne() {
        #expect(UnderlineView.dots(in: CGRect(x: 10, y: 5, width: 3, height: 2)) == [CGRect(x: 10, y: 5, width: 2, height: 2)])
        #expect(UnderlineView.dots(in: CGRect(x: 0, y: 0, width: 9, height: 2)).map(\.minX) == [0, 4, 8])
        #expect(UnderlineView.dots(in: CGRect(x: 0, y: 0, width: 9, height: 2)).map(\.width) == [2, 2, 1])
        #expect(UnderlineView.dots(in: CGRect(x: 0, y: 0, width: 1, height: 2)).count == 1)
    }

    @MainActor @Test func theBadgeShowsACountOrATickAndSaysSo() {
        let view = BadgeView()
        view.show(.count(3), label: "3 suggestions: 3 spelling")
        #expect(view.accessibilityLabel() == "3 suggestions: 3 spelling" && view.content == .count(3))
        view.show(.tick, label: "No suggestions")
        #expect(view.accessibilityLabel() == "No suggestions" && view.content == .tick)
    }
}
