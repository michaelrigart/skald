import AppKit

/// A small circle with the field's issue count. Clicking it opens the cards as a list; the click never
/// activates Skald or takes focus from the field's app.
final class BadgeView: NSView {
    var count = 0 {
        didSet {
            if count != oldValue { needsDisplay = true }
            setAccessibilityLabel(count == 1 ? "1 suggestion" : "\(count) suggestions")
        }
    }

    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let label = count > 99 ? "99+" : "\(count)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: count > 9 ? 9 : 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}

/// The badge's own panel at the field's corner.
final class BadgePanel {
    private let panel = OverlayPanel(size: CGSize(width: OverlayGeometry.badgeDiameter, height: OverlayGeometry.badgeDiameter))
    private let view = BadgeView()

    init(onClick: @escaping () -> Void) {
        view.onClick = onClick
        panel.hasShadow = false
        panel.contentView = view
    }

    var frame: CGRect? { panel.isVisible ? panel.frame : nil }

    func show(count: Int, at frame: CGRect) {
        view.count = count
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        panel.orderOut(nil)
    }
}
