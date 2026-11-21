import AppKit
import SkaldCore

/// What the badge shows: the field's issue count, or a quiet tick for a checked field with none.
enum BadgeContent: Equatable {
    case count(Int), tick

    /// Only a count does anything when clicked; a tick lets the click through to the field.
    var takesClicks: Bool {
        if case .count = self { return true }
        return false
    }

    /// What the badge shows after a snapshot; nil hides it. A snapshot that isn't `checked` is a recheck of the
    /// same field in progress, or a new field, or a pause: the badge keeps what it showed only for the first.
    static func next(current: BadgeContent?, issues: Int, checked: Bool, sameField: Bool, paused: Bool) -> BadgeContent? {
        if issues > 0 { return .count(issues) }
        if checked { return .tick }
        return sameField && !paused ? current : nil
    }
}

/// What the badge shows and says aloud. A held count keeps the label it was given with, so the badge and VoiceOver agree.
struct BadgeState: Equatable {
    let content: BadgeContent
    let label: String

    /// `BadgeContent.next` with the label: recomputed when the content is new (issues, or a checked field),
    /// kept with the content when it is held across a recheck.
    static func next(current: BadgeState?, issues: [Issue], checked: Bool, sameField: Bool, paused: Bool) -> BadgeState? {
        let content = BadgeContent.next(current: current?.content, issues: issues.count, checked: checked, sameField: sameField, paused: paused)
        guard let content else { return nil }
        if issues.isEmpty, !checked { return current }
        return BadgeState(content: content, label: OverlayGeometry.badgeLabel(issues))
    }
}

/// A small circle with the field's issue count, or a tick. Clicking a count opens the cards as a list; the
/// click never activates Skald or takes focus from the field's app. A tick does nothing, and its panel lets
/// clicks through to the field.
final class BadgeView: NSView {
    static let tickOpacity: CGFloat = 0.6

    private(set) var content = BadgeContent.tick

    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ content: BadgeContent, label: String) {
        if content != self.content { needsDisplay = true }
        self.content = content
        alphaValue = content == .tick ? Self.tickOpacity : 1
        setAccessibilityRole(content.takesClicks ? .button : .staticText)
        setAccessibilityLabel(label)
    }

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        _ = press()
    }

    override func accessibilityPerformPress() -> Bool {
        press()
    }

    private func press() -> Bool {
        guard content.takesClicks else { return false }
        onClick?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        switch content {
        case .count(let count): drawCount(count)
        case .tick: drawTick()
        }
    }

    private func drawCount(_ count: Int) {
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

    /// An SF Symbol checkmark in a grey circle; `show` sets the whole view to 60 % opacity.
    private func drawTick() {
        NSColor.systemGray.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold).applying(.init(paletteColors: [.white]))
        guard let tick = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let size = tick.size
        tick.draw(in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
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

    func show(_ content: BadgeContent, label: String, at frame: CGRect) {
        view.show(content, label: label)
        panel.ignoresMouseEvents = !content.takesClicks
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        panel.orderOut(nil)
    }
}
