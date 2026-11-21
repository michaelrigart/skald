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

    @MainActor @Test func theBadgeShowsACountOrATickAndSaysSo() {
        let view = BadgeView()
        view.show(.count(3), label: "3 suggestions: 3 spelling")
        #expect(view.accessibilityLabel() == "3 suggestions: 3 spelling" && view.content == .count(3))
        view.show(.tick, label: "No suggestions")
        #expect(view.accessibilityLabel() == "No suggestions" && view.content == .tick)
    }
}
