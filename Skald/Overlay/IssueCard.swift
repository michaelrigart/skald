import AppKit
import SkaldCore
import SwiftUI

/// A borderless `.nonactivatingPanel` that never becomes key or main, so the field's app keeps focus while
/// the user clicks in it, which the paste writer's checks need.
final class OverlayPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = Self.level
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
    }

    /// Above the underline windows, which sit at `.floating`.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click, since its window is never key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The cards one panel shows: one from an underline, or the badge's list.
@Observable final class CardStack {
    private(set) var cards: [IssueCardModel] = []

    func set(_ cards: [IssueCardModel]) {
        self.cards = cards
    }

    func remove(_ id: UUID) {
        cards.removeAll { $0.id == id }
    }
}

/// The panel that shows a card or the badge's list, placed by `OverlayGeometry.cardOrigin` and kept with
/// its edge next to the anchor as the cards change size.
final class CardPanel {
    private let stack = CardStack()
    private let panel = OverlayPanel(size: CGSize(width: CardPanel.width, height: 100))
    private var anchor: CGRect = .zero
    private var screen: CGRect = .zero
    static let width: CGFloat = 320

    var onEmpty: (() -> Void)?

    init() {
        let host = FirstClickHostingView(rootView: CardStackView(stack: stack) { [weak self] size in self?.fit(size) })
        host.sizingOptions = []
        panel.contentView = host
    }

    var isOpen: Bool { panel.isVisible }
    var frame: CGRect { panel.frame }
    var cards: [IssueCardModel] { stack.cards }
    /// True while any card is working or showing an outcome; such a panel stays put.
    var isBusy: Bool { stack.cards.contains { $0.phase != .ready } }

    func show(_ cards: [IssueCardModel], anchor: CGRect, screen: CGRect) {
        for card in cards {
            card.onClose = { [weak self, id = card.id] in self?.closed(id) }
        }
        self.anchor = anchor
        self.screen = screen
        stack.set(cards)
        let size = panel.contentView?.fittingSize ?? CGSize(width: Self.width, height: 100)
        place(size)
        panel.orderFrontRegardless()
    }

    /// Keeps the cards for which `keep` holds and closes the panel when none is left.
    func retain(where keep: (IssueCardModel) -> Bool) {
        for card in stack.cards where !keep(card) { stack.remove(card.id) }
        if stack.cards.isEmpty { close() }
    }

    func close() {
        stack.set([])
        panel.orderOut(nil)
        onEmpty?()
    }

    private func closed(_ id: UUID) {
        stack.remove(id)
        if stack.cards.isEmpty { close() }
    }

    private func fit(_ size: CGSize) {
        guard panel.isVisible, size.height > 0, panel.frame.size != size else { return }
        place(size)
    }

    private func place(_ size: CGSize) {
        let origin = OverlayGeometry.cardOrigin(size: size, anchor: anchor, within: screen)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}

private struct CardStackView: View {
    let stack: CardStack
    let resized: (CGSize) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stack.cards.enumerated()), id: \.element.id) { index, card in
                if index > 0 { Divider() }
                IssueCardView(card: card)
            }
        }
        .frame(width: CardPanel.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .environment(\.controlActiveState, .key)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { resized($0) }
    }
}

private struct IssueCardView: View {
    let card: IssueCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(change)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            switch card.phase {
            case .ready:
                HStack(spacing: 6) {
                    if card.offersAccept {
                        Button("Accept") { Task { await card.accept() } }
                            .buttonStyle(.borderedProminent)
                    }
                    copyButton
                    Button("Ignore") { card.ignore() }
                    if let word = card.neverFlagWord {
                        Button("Never flag “\(word)”") { card.neverFlag() }
                            .lineLimit(1)
                    }
                }
            case .working:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Applying the fix…").foregroundStyle(.secondary)
                }
            case .finished(let reason, _):
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    copyButton
                    Button("Close") { card.close() }
                }
            case .closed:
                EmptyView()
            }
        }
        .controlSize(.small)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var copyButton: some View {
        if card.offersCopy {
            Button(card.copied ? "Copied" : "Copy fix") { card.copyFix() }
        }
    }

    private var change: AttributedString {
        let content = card.content
        var text = AttributedString(content.before)
        if !content.original.isEmpty {
            var original = AttributedString(content.original)
            original.strikethroughStyle = .single
            original.foregroundColor = .secondary
            text += original
        }
        if !content.replacement.isEmpty {
            var replacement = AttributedString((content.original.isEmpty ? "" : " ") + content.replacement)
            replacement.foregroundColor = .accentColor
            replacement.inlinePresentationIntent = .stronglyEmphasized
            text += replacement
        }
        text += AttributedString(content.after)
        return text
    }
}
