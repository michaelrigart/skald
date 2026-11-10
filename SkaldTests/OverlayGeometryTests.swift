import CoreGraphics
import Foundation
import SkaldCore
import Testing
@testable import Skald
import struct SkaldCore.Issue

/// The badge and the cards follow the focused editor onto any Space, as the underline windows do; a window with
/// no collection behaviour stays on the Space it first appeared on.
struct OverlaySpacesTests {
    @MainActor @Test func theBadgeAndCardPanelsJoinEverySpace() {
        let panel = OverlayPanel(size: CGSize(width: 10, height: 10))
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(!panel.collectionBehavior.contains(.moveToActiveSpace))
    }
}

struct OverlayGeometryTests {
    /// Accessibility measures from the primary screen's top-left corner, AppKit from its bottom-left.
    @Test func theUnderlineIsTwoPointsAlongTheBottomOfTheBoundsInAppKitCoordinates() {
        let bounds = CGRect(x: 100, y: 200, width: 50, height: 18)
        let underline = OverlayGeometry.underline(for: bounds, primaryHeight: 1000)
        #expect(underline == CGRect(x: 100, y: 782, width: 50, height: 2))
    }

    /// Catches a flip against the field's own screen instead of the primary screen.
    @Test func anUnderlineOnAScreenAboveThePrimaryOneKeepsItsPlace() {
        let bounds = CGRect(x: 300, y: -500, width: 40, height: 16)
        let underline = OverlayGeometry.underline(for: bounds, primaryHeight: 1080)
        #expect(underline == CGRect(x: 300, y: 1564, width: 40, height: 2))
    }

    @Test func theBadgeSitsInsideTheFieldsBottomRightCornerOnASecondaryScreenWithANegativeOrigin() {
        // A secondary screen above and to the left of a 1080-point-high primary screen: AX origin (-1920, -1200).
        let field = CGRect(x: -1500, y: -900, width: 400, height: 200)
        let badge = OverlayGeometry.badgeFrame(for: field, primaryHeight: 1080)
        // AppKit: the field spans y 1780...1980; the badge is 18 points wide, 4 points in from the corner.
        #expect(badge == CGRect(x: -1122, y: 1784, width: 18, height: 18))
    }

    @Test func anUnderlineInsideTheFieldIsShown() {
        let field = CGRect(x: 100, y: 100, width: 400, height: 300)
        #expect(OverlayGeometry.isVisible(CGRect(x: 120, y: 380, width: 60, height: 18), in: field))
    }

    /// Scrolled out of view: the app still reports bounds, above or below the field.
    @Test func anUnderlineScrolledOutOfTheFieldIsHidden() {
        let field = CGRect(x: 100, y: 100, width: 400, height: 300)
        #expect(!OverlayGeometry.isVisible(CGRect(x: 120, y: 60, width: 60, height: 18), in: field))
        #expect(!OverlayGeometry.isVisible(CGRect(x: 120, y: 395, width: 60, height: 18), in: field))
        #expect(!OverlayGeometry.isVisible(CGRect(x: 120, y: 900, width: 60, height: 18), in: field))
    }

    @Test func boundsReachingTwoPointsPastTheFieldStillCount() {
        let field = CGRect(x: 100, y: 100, width: 400, height: 300)
        #expect(OverlayGeometry.isVisible(CGRect(x: 98, y: 98, width: 60, height: 18), in: field))
    }

    @Test func withoutAFieldFrameEveryUnderlineIsShown() {
        #expect(OverlayGeometry.isVisible(CGRect(x: 120, y: 60, width: 60, height: 18), in: nil))
    }

    @Test func aCardOpensBelowTheWordWhenThereIsRoom() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let word = CGRect(x: 200, y: 500, width: 60, height: 18)
        let origin = OverlayGeometry.cardOrigin(size: CGSize(width: 300, height: 120), anchor: word, within: screen)
        #expect(origin == CGPoint(x: 200, y: 376))
    }

    @Test func aCardNearTheScreensBottomOpensAboveTheWordAndStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let word = CGRect(x: 1300, y: 60, width: 60, height: 18)
        let origin = OverlayGeometry.cardOrigin(size: CGSize(width: 300, height: 120), anchor: word, within: screen)
        #expect(origin == CGPoint(x: 1140, y: 82))
    }

    @Test func aBadgeListTallerThanTheScreenIsBoundedToItsVisibleFrame() {
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 835)
        let badge = CGRect(x: 1300, y: 300, width: 18, height: 18)
        let frame = OverlayGeometry.cardFrame(fitting: CGSize(width: 320, height: 2400), anchor: badge, within: visible)
        #expect(frame == CGRect(x: 1120, y: 40, width: 320, height: 835))
    }

    @Test func aCardThatFitsKeepsItsSizeAndPlace() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let word = CGRect(x: 200, y: 500, width: 60, height: 18)
        let frame = OverlayGeometry.cardFrame(fitting: CGSize(width: 300, height: 120), anchor: word, within: screen)
        #expect(frame == CGRect(x: 200, y: 376, width: 300, height: 120))
    }

    @Test func aChangedWordIsUnderlinedWhereItStands() {
        let flagged = issue(in: "They is ready", revised: "They are ready", at: 40)
        #expect(OverlayGeometry.underlineRange(for: flagged) == TextRange(location: 45, length: 2))
    }

    /// Review focus 1: the range is in UTF-16 units, so an emoji before the word must not shift it.
    @Test func anEmojiBeforeTheWordLeavesTheUnderlineOnTheWord() {
        let text = "👍🏽 Ik heb het gedownloaded"
        let flagged = issue(in: text, revised: "👍🏽 Ik heb het gedownload")
        let range = OverlayGeometry.underlineRange(for: flagged)
        #expect((text as NSString).substring(with: NSRange(location: range.location, length: range.length)) == "gedownloaded")
    }

    /// An insertion has an empty range; the gap it goes into is underlined instead.
    @Test func aMissingCommaUnderlinesTheGapItBelongsIn() {
        let flagged = issue(in: "Hello world", revised: "Hello, world")
        #expect(OverlayGeometry.underlineRange(for: flagged) == TextRange(location: 5, length: 1))
    }

    @Test func aMissingFullStopAtTheEndUnderlinesTheLastCharacter() {
        let flagged = issue(in: "Hello world", revised: "Hello world.")
        #expect(OverlayGeometry.underlineRange(for: flagged) == TextRange(location: 10, length: 1))
    }

    // MARK: Which issues to ask bounds for

    private let visible = TextRange(location: 100, length: 50)

    /// A one-word replacement whose word spans `start..<start + 10`.
    private func word(at start: Int) -> Issue {
        issue(in: "aaaa bbbbbbbbbb cc", revised: "aaaa cccccccccc cc", at: start - 5)
    }

    /// A missing full stop after "Hello world" starting at `start`: the last character is underlined.
    private func missingStop(after start: Int) -> Issue {
        issue(in: "Hello world", revised: "Hello world.", at: start)
    }

    @Test func onlyIssuesWhoseUnderlineMeetsTheVisibleRangeAreAskedFor() {
        let above = word(at: 20)
        let straddlingStart = word(at: 95)
        let inside = word(at: 120)
        let straddlingEnd = word(at: 145)
        let below = word(at: 300)
        let all = [above, straddlingStart, inside, straddlingEnd, below]
        #expect(OverlayGeometry.issues(all, meeting: visible).map(\.id) == [straddlingStart, inside, straddlingEnd].map(\.id))
    }

    @Test func anInsertionsUnderlineCountsWhereItLiesInTheVisibleRange() {
        let gap = issue(in: "Hello world", revised: "Hello, world", at: 120)
        #expect(OverlayGeometry.underlineRange(for: gap) == TextRange(location: 125, length: 1))
        let lastInside = missingStop(after: 139)
        #expect(OverlayGeometry.underlineRange(for: lastInside) == TextRange(location: 149, length: 1))
        let pastTheEnd = missingStop(after: 140)
        #expect(OverlayGeometry.underlineRange(for: pastTheEnd) == TextRange(location: 150, length: 1))
        let justBefore = missingStop(after: 90)
        #expect(OverlayGeometry.underlineRange(for: justBefore) == TextRange(location: 100, length: 1))
        let endsAtTheStart = missingStop(after: 89)
        #expect(OverlayGeometry.underlineRange(for: endsAtTheStart) == TextRange(location: 99, length: 1))
        let all = [gap, lastInside, pastTheEnd, justBefore, endsAtTheStart]
        #expect(OverlayGeometry.issues(all, meeting: visible).map(\.id) == [gap, lastInside, justBefore].map(\.id))
    }

    @Test func aZeroLengthRangeCountsInsideTheVisibleRangeAndOnEitherEdge() {
        for location in [100, 125, 150] {
            #expect(OverlayGeometry.meets(TextRange(location: location, length: 0), visible: visible))
        }
        for location in [99, 151] {
            #expect(!OverlayGeometry.meets(TextRange(location: location, length: 0), visible: visible))
        }
    }

    @Test func aRangeTouchingTheVisibleRangeOnlyAtAnEdgeDoesNotMeetIt() {
        #expect(!OverlayGeometry.meets(TextRange(location: 90, length: 10), visible: visible))
        #expect(!OverlayGeometry.meets(TextRange(location: 150, length: 5), visible: visible))
        #expect(OverlayGeometry.meets(TextRange(location: 90, length: 11), visible: visible))
        #expect(OverlayGeometry.meets(TextRange(location: 149, length: 5), visible: visible))
    }

    @Test func withoutAVisibleRangeEveryIssueIsAskedFor() {
        let all = [word(at: 20), word(at: 120), word(at: 300)]
        #expect(OverlayGeometry.issues(all, meeting: nil).map(\.id) == all.map(\.id))
    }
}
