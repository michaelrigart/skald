import AppKit
import SkaldCore

/// Draws 2-point underlines at rects in its own coordinates; red for spelling, blue for the model's fixes.
final class UnderlineView: NSView {
    struct Mark: Equatable {
        let rect: CGRect
        let source: IssueSource
    }

    var marks: [Mark] = [] {
        didSet { if marks != oldValue { needsDisplay = true } }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        for mark in marks where mark.rect.intersects(dirtyRect) {
            Self.color(mark.source).setFill()
            NSBezierPath(roundedRect: mark.rect, xRadius: 1, yRadius: 1).fill()
        }
    }

    private static func color(_ source: IssueSource) -> NSColor {
        switch source {
        case .spelling: .systemRed
        case .model: .systemBlue
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
            .map { UnderlineView.Mark(rect: $0.rect.offsetBy(dx: -origin.x, dy: -origin.y), source: $0.source) }
        underlines.marks = local
        if local.isEmpty {
            orderOut(nil)
        } else if !isVisible {
            orderFrontRegardless()
        }
    }
}
