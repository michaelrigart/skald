import CoreGraphics
import SkaldCore

/// Where the overlay draws. Accessibility reports rects from the primary screen's top-left corner, y down;
/// AppKit places windows from its bottom-left corner, y up. Every rect in and out says which it is.
enum OverlayGeometry {
    static let underlineThickness: CGFloat = 2
    static let badgeDiameter: CGFloat = 18
    static let badgeInset: CGFloat = 4
    static let cardGap: CGFloat = 4
    /// Apps report bounds a point or two past their own frame at the edges.
    static let fieldSlack: CGFloat = 2

    /// An Accessibility rect in AppKit's global coordinates.
    static func appKit(_ ax: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: ax.minX, y: primaryHeight - ax.maxY, width: ax.width, height: ax.height)
    }

    /// The underline for a range's Accessibility bounds: the bottom two points of the line box, in AppKit
    /// coordinates, so it never reaches into the next line or past the field's last line.
    static func underline(for bounds: CGRect, primaryHeight: CGFloat) -> CGRect {
        let box = appKit(bounds, primaryHeight: primaryHeight)
        return CGRect(x: box.minX, y: box.minY, width: box.width, height: underlineThickness)
    }

    /// False when a range's bounds lie outside the field's frame, both in Accessibility coordinates: the text
    /// is scrolled out of view. Without a frame there is nothing to clip against.
    static func isVisible(_ bounds: CGRect, in field: CGRect?) -> Bool {
        guard let field else { return true }
        return field.insetBy(dx: -fieldSlack, dy: -fieldSlack).contains(bounds)
    }

    /// The badge inside the field's bottom-right corner, in AppKit coordinates.
    static func badgeFrame(for field: CGRect, primaryHeight: CGFloat) -> CGRect {
        let frame = appKit(field, primaryHeight: primaryHeight)
        return CGRect(
            x: frame.maxX - badgeInset - badgeDiameter, y: frame.minY + badgeInset,
            width: badgeDiameter, height: badgeDiameter
        )
    }

    /// A card's origin below `anchor`, or above it when the screen ends first, kept inside `screen`; all
    /// in AppKit coordinates.
    static func cardOrigin(size: CGSize, anchor: CGRect, within screen: CGRect) -> CGPoint {
        var y = anchor.minY - cardGap - size.height
        if y < screen.minY { y = anchor.maxY + cardGap }
        y = min(max(y, screen.minY), screen.maxY - size.height)
        let x = min(max(anchor.minX, screen.minX), screen.maxX - size.width)
        return CGPoint(x: x, y: y)
    }

    /// The field range to underline. An insertion has an empty range, so its gap is underlined instead, or
    /// the character next to it at the paragraph's end or start.
    static func underlineRange(for issue: Issue) -> TextRange {
        let base = issue.chunk.range.location
        let edit = issue.edit
        if edit.range.length > 0 { return issue.fieldRange }
        if edit.spliceRange.length > 0 {
            return TextRange(location: base + edit.spliceRange.location, length: edit.spliceRange.length)
        }
        if edit.range.location > 0 { return TextRange(location: base + edit.range.location - 1, length: 1) }
        return TextRange(location: base, length: min(1, issue.chunk.range.length))
    }
}
