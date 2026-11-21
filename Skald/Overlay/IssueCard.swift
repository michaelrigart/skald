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
        collectionBehavior = Self.spaces
    }

    /// On every Space, like the underline windows: the field's app can be focused on any of them, and a panel
    /// tied to the Space it first appeared on would not come forward on another.
    static let spaces: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]

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

/// The panel that shows a card or the badge's list, placed by `OverlayGeometry.cardFrame` and kept with
/// its edge next to the anchor as the cards change size; a list taller than the screen scrolls.
final class CardPanel {
    private let stack = CardStack()
    private let panel = OverlayPanel(size: CGSize(width: CardPanel.width, height: 100))
    private(set) var anchor: CGRect = .zero
    private(set) var screen: CGRect = .zero
    /// The cards' size as the view last laid them out. A hidden window is not laid out, so a panel shown again with
    /// the same cards gets no new size from the view; this is the size it keeps.
    private var contentSize: CGSize?
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
        place(contentSize ?? panel.contentView?.fittingSize ?? CGSize(width: Self.width, height: 100))
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

    /// `size` is the cards' own size, before the screen bounds it. It arrives during the view's layout, which
    /// a resize of the panel must not re-enter, so the panel follows on the next turn of the main loop.
    private func fit(_ size: CGSize) {
        guard size.height > 0 else { return }
        contentSize = size
        Task { @MainActor [weak self] in
            guard let self, let size = contentSize else { return }
            let frame = OverlayGeometry.cardFrame(fitting: size, anchor: anchor, within: screen)
            guard panel.frame != frame else { return }
            panel.setFrame(frame, display: true)
        }
    }

    private func place(_ size: CGSize) {
        panel.setFrame(OverlayGeometry.cardFrame(fitting: size, anchor: anchor, within: screen), display: true)
    }
}

private struct CardStackView: View {
    let stack: CardStack
    let resized: (CGSize) -> Void

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(stack.cards.enumerated()), id: \.element.id) { index, card in
                    if index > 0 { Divider() }
                    IssueCardView(card: card)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { resized($0) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: CardPanel.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .environment(\.controlActiveState, .key)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestions")
    }
}

private struct IssueCardView: View {
    let card: IssueCardModel

    var body: some View {
        if card.phase == .notice {
            Text(IssueCardModel.clipboardNotice)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { card.close() }
        } else {
            choices
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(nsColor: CategoryPalette.color(card.kind.category)))
                            .frame(width: 8, height: 8)
                        Text(card.headline)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(change)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(card.label)
                Spacer(minLength: 0)
                if card.byClaude {
                    Text("Claude")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            switch card.phase {
            case .ready:
                if card.offersAlternatives {
                    HStack(spacing: 6) {
                        ForEach(Array(card.alternatives.enumerated()), id: \.offset) { index, guess in
                            let copied = card.copiedAlternative == index
                            Button(copied ? "Copied" : guess) {
                                if card.writes { Task { await card.accept(alternative: index) } } else { card.copy(alternative: index) }
                            }
                            .lineLimit(1)
                            .accessibilityLabel("\(card.writes ? "Use" : copied ? "Copied" : "Copy") \(guess): \(card.label)")
                        }
                    }
                }
                HStack(spacing: 6) {
                    if card.offersAccept {
                        Button("Accept") { Task { await card.accept() } }
                            .buttonStyle(.borderedProminent)
                            .accessibilityLabel("Accept: \(card.label)")
                    }
                    copyButton
                    Button("Dismiss") { card.dismiss() }
                        .accessibilityLabel("Dismiss: \(card.label)")
                    Spacer(minLength: 0)
                    moreMenu
                }
                if card.showsReviewKeys {
                    Text(IssueCardModel.reviewKeys)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        .accessibilityLabel("Close: \(card.label)")
                }
            case .notice, .closed:
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
                .accessibilityLabel("\(card.copied ? "Copied" : "Copy fix"): \(card.label)")
        }
    }

    /// The panel never becomes key, so the menu opens over the field's app without activating Skald.
    @ViewBuilder private var moreMenu: some View {
        if card.hideTitle != nil || card.dictionaryTitle != nil || card.canCopyFix {
            Menu {
                if let title = card.hideTitle {
                    Button(title) { card.hide() }
                        .accessibilityLabel("\(title): \(card.label)")
                }
                if let title = card.dictionaryTitle {
                    Button(title) { card.addToDictionary() }
                        .accessibilityLabel("\(title): \(card.label)")
                }
                if card.canCopyFix {
                    Button("Copy fix") { card.copyFix() }
                        .accessibilityLabel("Copy fix: \(card.label)")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More: \(card.label)")
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
