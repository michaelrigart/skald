import AppKit
import SkaldCore

/// Draws 2-point underlines at rects in its own coordinates, in the colour of their category; punctuation is dotted.
final class UnderlineView: NSView {
    struct Mark: Equatable {
        let rect: CGRect
        let category: IssueCategory
    }

    var marks: [Mark] = [] {
        didSet { if marks != oldValue { needsDisplay = true } }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        for mark in marks where mark.rect.intersects(dirtyRect) {
            CategoryPalette.color(mark.category).setFill()
            if CategoryPalette.isDotted(mark.category) {
                Self.dots(in: mark.rect).forEach { $0.fill() }
            } else {
                NSBezierPath(roundedRect: mark.rect, xRadius: 1, yRadius: 1).fill()
            }
        }
    }

    /// 2-point squares every 4 points along the rect, at least one; the last is cut at the rect's end.
    static func dots(in rect: CGRect) -> [NSBezierPath] {
        let count = max(1, Int((rect.width / 4).rounded(.up)))
        return (0..<count).map { index in
            let x = rect.minX + CGFloat(index) * 4
            return NSBezierPath(rect: CGRect(x: x, y: rect.minY, width: min(2, rect.maxX - x), height: rect.height))
        }
    }
}

/// One transparent window over a whole screen that the pointer passes through, above normal windows.
final class UnderlineWindow: NSWindow {
    let underlines = UnderlineView()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = underlines
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Takes underlines in AppKit's global coordinates; the parts off this screen are clipped.
    func show(_ global: [UnderlineView.Mark]) {
        let origin = frame.origin
        let local = global
            .filter { $0.rect.intersects(frame) }
            .map { UnderlineView.Mark(rect: $0.rect.offsetBy(dx: -origin.x, dy: -origin.y), category: $0.category) }
        underlines.marks = local
        if local.isEmpty {
            orderOut(nil)
        } else if !isVisible {
            orderFrontRegardless()
        }
    }
}
