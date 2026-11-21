import AppKit
import SkaldCore
import SkaldPlatform27

/// Shows the pipeline's issues over the focused field: underlines where the app reports range bounds, a
/// badge at the field's corner where it reports only the field's frame, nothing otherwise. Redraws on every
/// issue snapshot, on the field's window moves and caret moves; hides the underlines on a scroll and shows
/// them again once the app's bounds have settled (`ScrollSettle`); hides on focus loss.
/// Review mode (`ReviewSession`) steps through the issues from the keyboard while its card is open; it takes
/// snapshots, text changes, clicks elsewhere, a pause and `stop()` as the ways to end.
/// It posts no events and never takes focus; the only clipboard write is Copy fix.
final class OverlayController {
    static let hoverDelay: Duration = .milliseconds(300)

    private let pipeline: CheckPipeline
    private let access: SystemTextAccess
    private let settings: SettingsModel
    private let clipboard: any Clipboard
    private let sleep: (Duration) async throws -> Void
    private let stopwatch: Stopwatch
    private let registrar: any KeyRegistering
    private let announcer: any Announcing

    /// What one pass over the focused field reads: the marks, hover targets and badge place for a snapshot.
    private struct Layout {
        let generation: Int
        let marks: [UnderlineView.Mark]
        let targets: [HoverTracker.Target]
        /// In AppKit coordinates; nil where the app gives no field frame.
        let badgeFrame: CGRect?
    }

    /// Time since `start()` on the injected clock, for `ScrollSettle`.
    private final class Stopwatch {
        private let mark: () -> () -> Duration
        private var reader: () -> Duration = { .zero }

        init<C: Clock<Duration>>(_ clock: C) {
            mark = {
                let origin = clock.now
                return { origin.duration(to: clock.now) }
            }
        }

        func start() { reader = mark() }
        var elapsed: Duration { reader() }
    }

    private var snapshot = IssueSnapshot(field: nil, issues: [], checked: false)
    /// Bumped by every snapshot, so a redraw read for an older one is dropped.
    private var generation = 0
    private var capabilities: (field: FieldID, value: AccessCapabilities)?
    /// What the badge shows for the focused field; nil hides it. Kept across a recheck, so it doesn't blink.
    private var badgeState: BadgeState?
    /// One per focused field, made from its app's ceiling; hides the underlines on a scroll.
    private lazy var scroller = makeScroller(for: nil)
    private var windows: [UnderlineWindow] = []
    private lazy var badge = BadgePanel { [weak self] in self?.badgeClicked() }
    private let cards = CardPanel()
    private var parking = CardParking()
    private lazy var review = makeReview()
    /// The card review mode shows, and the read that places it when its word isn't drawn.
    private var reviewCard: IssueCardModel?
    private var reviewShow: Task<Void, Never>?
    /// The word a hover card belongs to, or nil while the badge's list or nothing is open.
    private var cardAnchor: CGRect?
    private var hover = HoverTracker()
    private var targets: [HoverTracker.Target] = []
    private var dwell: Task<Void, Never>?
    private var redraw: Task<Void, Never>?
    private var redrawAgain = false
    private var streams: [Task<Void, Never>] = []
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?

    init<C: Clock<Duration>>(
        pipeline: CheckPipeline, access: SystemTextAccess, settings: SettingsModel, clipboard: any Clipboard, clock: C,
        registrar: any KeyRegistering, announcer: any Announcing
    ) {
        self.registrar = registrar
        self.announcer = announcer
        self.pipeline = pipeline
        self.access = access
        self.settings = settings
        self.clipboard = clipboard
        sleep = { try await clock.sleep(for: $0) }
        stopwatch = Stopwatch(clock)
        cards.onEmpty = { [weak self] in self?.cardAnchor = nil }
    }

    func start() {
        guard streams.isEmpty else { return }
        stopwatch.start()
        buildWindows()
        let issues = pipeline.issues
        let geometry = access.geometryChanges
        streams = [
            Task { [weak self] in
                for await snapshot in issues { self?.received(snapshot) }
            },
            Task { [weak self] in
                for await change in geometry {
                    switch change {
                    case .window: self?.moved(.window)
                    case .caret: self?.moved(.caret)
                    case .text: self?.moved(.edit)
                    }
                }
            },
        ]
        monitor(.mouseMoved) { $0.pointerMoved() }
        monitor(.scrollWheel) { $0.moved(.scroll) }
        monitor([.leftMouseDown, .rightMouseDown, .otherMouseDown]) { $0.clickedElsewhere() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.buildWindows()
                self?.requestRedraw()
            }
        }
    }

    func stop() {
        review.left()
        streams.forEach { $0.cancel() }
        streams = []
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        dwell?.cancel()
        redraw?.cancel()
        reviewShow?.cancel()
        scroller.cancel()
        hideMarks()
        parking.otherCardOpened()
        cards.close()
        windows.forEach { $0.close() }
        windows = []
    }

    // MARK: Inputs

    private func received(_ new: IssueSnapshot) {
        generation += 1
        let fieldChanged = new.field != snapshot.field
        if fieldChanged {
            capabilities = nil
            scroller.cancel()
            scroller = makeScroller(for: new.field)
        }
        let paused = settings.settings.pausedUntil.map { $0 > .now } ?? false
        badgeState = BadgeState.next(
            current: badgeState, issues: OverlayGeometry.distinct(new.issues), checked: new.checked,
            sameField: new.field != nil && !fieldChanged, paused: paused
        )
        snapshot = IssueSnapshot(field: new.field, issues: OverlayGeometry.distinct(new.issues), checked: new.checked)
        let visible = Set(snapshot.issues.map(\.id))
        cards.retain { $0.survives(visible: visible, in: new.field) }
        if let parked = parking.received(snapshot), !cards.isOpen {
            cards.show([parked.card], anchor: parked.anchor, screen: parked.screen)
            cardAnchor = nil
        }
        // Every snapshot, in the order the pipeline publishes them: review mode waits for a recheck by their order.
        review.snapshot(snapshot.issues, checked: new.checked, sameField: new.field != nil && !fieldChanged)
        if fieldChanged || snapshot.issues.isEmpty { hideUnderlines() }
        if fieldChanged || badgeState == nil { badge.hide() }
        requestRedraw()
    }

    /// The words may be elsewhere now. A scroll hides the underlines, leaves their reading to `scroller` and
    /// moves the badge with its field; a window move or a caret move reads the marks again, and a window move closes a card that is only offering
    /// its choices; an edit closes a clipboard notice. A text or caret change also ends a scroll's hiding.
    private func moved(_ change: LayoutChange) {
        if change == .edit { review.edited() }
        if change == .scroll {
            scroller.scrolled()
            return requestRedraw()
        }
        if change != .caret, !review.isOpen { cards.retain { $0.survives(change) } }
        if change == .window { resetHover() }
        if change == .edit || change == .caret { scroller.redrawn() }
        requestRedraw()
    }

    private func makeScroller(for field: FieldID?) -> ScrollSettler<Layout> {
        ScrollSettler(
            ceiling: field.flatMap { ScrollLag.ceiling(for: $0.app) },
            sleep: sleep,
            now: { [stopwatch] in stopwatch.elapsed },
            layout: { [weak self] in
                guard let self else { return Layout(generation: -1, marks: [], targets: [], badgeFrame: nil) }
                return await self.readWhileHidden()
            },
            rects: { $0.marks.map(\.rect) },
            hide: { [weak self] in self?.scrollHid() },
            show: { [weak self] in self?.settled($0) }
        )
    }

    /// A scroll hides the underlines and closes a card that is only offering its choices; the badge stays.
    private func scrollHid() {
        if !review.isOpen { cards.retain { $0.survives(.scroll) } }
        hideUnderlines()
    }

    /// A read for the scroll rule; it moves the badge too, since a scroll can move the field.
    private func readWhileHidden() async -> Layout {
        let layout = await layout()
        if layout.generation == generation { showBadge(at: layout.badgeFrame) }
        return layout
    }

    /// The reads agreed: this layout is shown, unless a newer snapshot has made it stale, then it is read again.
    private func settled(_ layout: Layout) {
        guard layout.generation == generation else { return requestRedraw() }
        show(layout.marks, targets: layout.targets)
        showBadge(at: layout.badgeFrame)
    }

    private func pointerMoved() {
        let point = NSEvent.mouseLocation
        if let cardAnchor, !cards.isBusy, !HoverTracker.keepsCard(at: point, anchor: cardAnchor, card: cards.frame) {
            cards.close()
        }
        switch hover.pointer(at: point, over: targets, covered: cards.isOpen ? cards.frame : nil) {
        case .unchanged: break
        case .entered(let id): if !review.isOpen { wait(for: id) }
        case .left: dwell?.cancel()
        }
    }

    /// A click in another app closes every card except one still applying its fix.
    private func clickedElsewhere() {
        review.left()
        cards.retain { $0.phase == .working }
        resetHover()
    }

    private func badgeClicked() {
        review.left()
        guard !cards.isBusy else { return }
        if cards.isOpen, cardAnchor == nil { return cards.close() }
        guard let frame = badge.frame, !snapshot.issues.isEmpty else { return }
        open(snapshot.issues.map(card), anchor: frame, hoverAnchor: nil)
    }

    // MARK: Review

    /// The review shortcut. The field's capabilities are read first when they aren't known yet, so a field that
    /// takes a clean write isn't taken for a read-only one.
    func toggleReview() {
        guard !review.isOpen, let field = snapshot.field, capabilities?.field != field else { return review.toggle() }
        Task { [weak self] in
            guard let self else { return }
            _ = await capabilities(of: field)
            review.toggle()
        }
    }

    /// A pause, or anything else that ends review mode from outside the overlay.
    func leaveReview() {
        review.left()
    }

    private func makeReview() -> ReviewSession {
        ReviewSession(
            keys: ReviewKeys(registrar: registrar, sleep: sleep), announcer: announcer, sleep: sleep,
            actions: .init(
                issues: { [weak self] in self?.snapshot.issues ?? [] },
                writes: { [weak self] in
                    guard let self, let field = snapshot.field else { return false }
                    return capabilities.map { $0.field == field && $0.value.contains(.cleanWrite) } ?? false
                },
                show: { [weak self] issue, _, _ in self?.showReviewCard(for: issue) },
                accept: { [weak self] id, alternative in await self?.acceptReviewed(id, alternative: alternative) ?? .failed },
                copy: { [weak self] id in self?.reviewCard(id)?.copyFix() },
                dismiss: { [weak self] id in self?.dismissReviewed(id) },
                showChecking: { [weak self] in self?.showChecking() },
                close: { [weak self] in self?.reviewClosed() }
            )
        )
    }

    private func reviewCard(_ id: UUID) -> IssueCardModel? {
        reviewCard.flatMap { $0.id == id ? $0 : nil }
    }

    /// The issue's card alone. It opens at once, over its drawn word or else the nearest known place, so what is
    /// on screen is what the keys act on; where the word isn't drawn, its bounds are read and the panel moves there.
    private func showReviewCard(for issue: Issue) {
        reviewShow?.cancel()
        let model = card(issue)
        model.reviewing = true
        model.reviewRoute = .init(
            accept: { [weak self] alternative in self?.review.accept(alternative: alternative) },
            dismiss: { [weak self] in self?.review.dismiss() }
        )
        reviewCard = model
        let drawn = targets.first(where: { $0.id == issue.id })?.rect
        open(
            [model],
            anchor: OverlayGeometry.provisionalReviewAnchor(
                drawn: drawn, panel: cards.isOpen ? cards.anchor : nil, badge: badge.frame, pointer: Self.pointer
            ),
            hoverAnchor: nil
        )
        guard drawn == nil else { return }
        reviewShow = Task { [weak self] in
            guard let self else { return }
            guard let anchor = await readAnchor(of: issue), !Task.isCancelled, reviewCard === model, cards.cards.contains(where: { $0 === model })
            else { return }
            let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
            cards.reanchor(anchor, screen: screen?.visibleFrame ?? anchor)
        }
    }

    /// The word's bounds read now, else the field's frame; nil when the app gives neither. The word's bounds are only
    /// asked of an app that gives range bounds.
    private func readAnchor(of issue: Issue) async -> CGRect? {
        guard let field = snapshot.field else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        if capabilities.map({ $0.field == field && $0.value.contains(.rangeBounds) }) ?? true,
           let read = await access.bounds([OverlayGeometry.underlineRange(for: issue)], in: field).first ?? nil {
            return OverlayGeometry.appKit(read, primaryHeight: primaryHeight)
        }
        if let badge = badge.frame { return badge }
        return await access.frame(of: field).map { OverlayGeometry.appKit($0, primaryHeight: primaryHeight) }
    }

    private static var pointer: CGRect { CGRect(origin: NSEvent.mouseLocation, size: .zero) }

    private func acceptReviewed(_ id: UUID, alternative: Int?) async -> ReplaceOutcome {
        guard let card = reviewCard(id) else { return .failed }
        await card.accept(alternative: alternative)
        return card.outcome ?? .failed
    }

    private func dismissReviewed(_ id: UUID) {
        if let card = reviewCard(id) {
            card.dismiss()
        } else {
            Task { [pipeline] in await pipeline.ignore(id) }
        }
    }

    private func showChecking() {
        parking.otherCardOpened()
        cards.showStatus(ReviewSession.checking, anchor: cards.anchor, screen: cards.screen)
        cardAnchor = nil
    }

    /// The mode ended: cards that are ready and the status line go; one still writing, or showing why a write
    /// didn't go through, stays.
    private func reviewClosed() {
        reviewShow?.cancel()
        reviewShow = nil
        reviewCard = nil
        cards.clearStatus()
        cards.retain { $0.phase != .ready }
    }

    // MARK: Cards

    private func wait(for id: UUID) {
        dwell?.cancel()
        let sleep = self.sleep
        dwell = Task { [weak self] in
            do { try await sleep(Self.hoverDelay) } catch { return }
            await self?.rested(on: id)
        }
    }

    /// The word is read again before its card opens: only where its underline was drawn does the card open;
    /// anywhere else, or unreadable, the marks are drawn again and the pointer must enter the word anew.
    private func rested(on id: UUID) async {
        guard !review.isOpen, hover.current == id, !cards.isBusy, !cards.cards.contains(where: { $0.id == id }),
              let field = snapshot.field, let issue = snapshot.issues.first(where: { $0.id == id })
        else { return }
        let generation = self.generation
        let read = await access.bounds([OverlayGeometry.underlineRange(for: issue)], in: field).first ?? nil
        guard !Task.isCancelled, generation == self.generation, hover.current == id, !cards.isBusy,
              let drawn = targets.first(where: { $0.id == id })?.rect
        else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        guard HoverTracker.isStill(drawn: drawn, read: read.map { OverlayGeometry.appKit($0, primaryHeight: primaryHeight) }) else {
            resetHover()
            return requestRedraw()
        }
        open([card(issue)], anchor: drawn, hoverAnchor: drawn)
    }

    private func open(_ models: [IssueCardModel], anchor: CGRect, hoverAnchor: CGRect?) {
        parking.otherCardOpened()
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        cards.show(models, anchor: anchor, screen: screen?.visibleFrame ?? anchor)
        cardAnchor = hoverAnchor
    }

    private func card(_ issue: Issue) -> IssueCardModel {
        let writes = capabilities.map { $0.field == issue.key.field && $0.value.contains(.cleanWrite) } ?? false
        let model = IssueCardModel(
            issue: issue, writes: writes, clipboard: clipboard,
            actions: .init(
                accept: { [pipeline] id, alternative in await pipeline.accept(id, alternative: alternative) },
                dismiss: { [pipeline] id in Task { await pipeline.ignore(id) } },
                addToDictionary: { [weak self] id in self?.addToDictionary(id) },
                hide: { [settings] kind in settings.hide(kind) }
            )
        )
        model.onFinish = { [weak self, weak model] in
            guard let self, let model else { return }
            self.finished(model)
        }
        return model
    }

    /// Rulings R121 and R123: a write that finished after focus moved hides its card, and parks it when unconfirmed.
    private func finished(_ card: IssueCardModel) {
        switch parking.finished(card, focused: snapshot.field, anchor: cards.anchor, screen: cards.screen) {
        case .stays: break
        case .hides: cards.retain { $0 !== card }
        case .closes: card.close()
        }
    }

    /// The pipeline drops every issue on the word; the settings model saves it and hands the new list on.
    private func addToDictionary(_ id: UUID) {
        Task { [pipeline, settings] in
            guard let word = await pipeline.neverFlag(id) else { return }
            settings.addNeverTouch(word)
        }
    }

    private func resetHover() {
        hover.reset()
        dwell?.cancel()
    }

    // MARK: Drawing

    /// One redraw at a time; inputs arriving meanwhile cost one more pass once it ends, however many came.
    private func requestRedraw() {
        guard redraw == nil else {
            redrawAgain = true
            return
        }
        redraw = Task { [weak self] in
            while let self {
                self.redrawAgain = false
                await self.drawMarks()
                guard self.redrawAgain, !Task.isCancelled else { break }
            }
            self?.redraw = nil
        }
    }

    private func drawMarks() async {
        let scroller = self.scroller
        let epoch = scroller.drawEpoch
        // While a scroll hides the underlines only the badge is drawn, and there are no hover targets.
        let layout = await layout(withMarks: !scroller.isHidden)
        guard layout.generation == generation else { return }
        if scroller === self.scroller, scroller.mayDrawMarks(since: epoch) { show(layout.marks, targets: layout.targets) }
        showBadge(at: layout.badgeFrame)
    }

    private func layout(withMarks: Bool = true) async -> Layout {
        let generation = self.generation
        let snapshot = self.snapshot
        let nothing = Layout(generation: generation, marks: [], targets: [], badgeFrame: nil)
        guard let field = snapshot.field else { return nothing }
        let capabilities = await capabilities(of: field)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

        if capabilities.contains(.rangeBounds) {
            let frame = await access.frame(of: field)
            var marks: [UnderlineView.Mark] = []
            var targets: [HoverTracker.Target] = []
            if withMarks, !snapshot.issues.isEmpty {
                let visible = await access.visibleRange(of: field)
                let issues = OverlayGeometry.issues(snapshot.issues, meeting: visible).sorted { $0.source == .model && $1.source != .model }
                Log.ui.debug("redraw: \(snapshot.issues.count, privacy: .public) issues, \(issues.count, privacy: .public) ranges asked")
                let allBounds = await access.bounds(issues.map(OverlayGeometry.underlineRange), in: field)
                for (issue, bounds) in zip(issues, allBounds) {
                    guard let bounds, OverlayGeometry.isVisible(bounds, in: frame) else { continue }
                    marks.append(.init(rect: OverlayGeometry.underline(for: bounds, primaryHeight: primaryHeight), category: issue.kind.category))
                    targets.append(.init(id: issue.id, rect: OverlayGeometry.appKit(bounds, primaryHeight: primaryHeight)))
                }
            }
            let badgeFrame = capabilities.contains(.fieldFrame) ? frame.map { OverlayGeometry.badgeFrame(for: $0, primaryHeight: primaryHeight) } : nil
            return Layout(generation: generation, marks: marks, targets: targets, badgeFrame: badgeFrame)
        } else if capabilities.contains(.fieldFrame), let frame = await access.frame(of: field) {
            let badgeFrame = OverlayGeometry.badgeFrame(for: frame, primaryHeight: primaryHeight)
            return Layout(generation: generation, marks: [], targets: [], badgeFrame: badgeFrame)
        }
        return nothing
    }

    /// The badge at the field's corner for what `next` says, beside underlines too; hidden without a frame.
    private func showBadge(at frame: CGRect?) {
        guard let badgeState, let frame else { return badge.hide() }
        badge.show(badgeState.content, label: badgeState.label, at: frame)
    }

    private func capabilities(of field: FieldID) async -> AccessCapabilities {
        if let capabilities, capabilities.field == field { return capabilities.value }
        let value = await access.capabilities(for: field.app)
        if snapshot.field == field { capabilities = (field, value) }
        return value
    }

    private func show(_ marks: [UnderlineView.Mark], targets: [HoverTracker.Target]) {
        windows.forEach { $0.show(marks) }
        self.targets = targets
        if let current = hover.current, !targets.contains(where: { $0.id == current }) { resetHover() }
    }

    private func hideMarks() {
        hideUnderlines()
        badge.hide()
    }

    private func hideUnderlines() {
        show([], targets: [])
        resetHover()
    }

    private func buildWindows() {
        windows.forEach { $0.close() }
        windows = NSScreen.screens.map { UnderlineWindow(screen: $0) }
    }

    private func monitor(_ mask: NSEvent.EventTypeMask, _ handle: @escaping @MainActor (OverlayController) -> Void) {
        let token = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handle(self)
            }
        }
        if let token { monitors.append(token) }
    }
}
