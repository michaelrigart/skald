import CoreGraphics
import Foundation
import SkaldCore
import Testing
@testable import Skald

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
}
