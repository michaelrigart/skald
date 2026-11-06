import AppKit
import SkaldCore
import SkaldPlatform27

/// Shows the pipeline's issues over the focused field: underlines where the app reports range bounds, a
/// badge at the field's corner where it reports only the field's frame, nothing otherwise. Redraws on every
/// issue snapshot, on the field's window moves and caret moves, and on scrolling; hides on focus loss.
/// It posts no events and never takes focus; the only clipboard write is Copy fix.
final class OverlayController {
    static let hoverDelay: Duration = .milliseconds(300)

    private let pipeline: CheckPipeline
    private let access: SystemTextAccess
    private let settings: SettingsModel
    private let clipboard: any Clipboard
    private let sleep: (Duration) async throws -> Void

    private var snapshot = IssueSnapshot(field: nil, issues: [])
    /// Bumped by every snapshot, so a redraw read for an older one is dropped.
    private var generation = 0
    private var capabilities: (field: FieldID, value: AccessCapabilities)?
    private var windows: [UnderlineWindow] = []
    private lazy var badge = BadgePanel { [weak self] in self?.badgeClicked() }
    private let cards = CardPanel()
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

    init<C: Clock<Duration>>(pipeline: CheckPipeline, access: SystemTextAccess, settings: SettingsModel, clipboard: any Clipboard, clock: C) {
        self.pipeline = pipeline
        self.access = access
        self.settings = settings
        self.clipboard = clipboard
        sleep = { try await clock.sleep(for: $0) }
        cards.onEmpty = { [weak self] in self?.cardAnchor = nil }
    }

    func start() {
        guard streams.isEmpty else { return }
        buildWindows()
        let issues = pipeline.issues
        let geometry = access.geometryChanges
        streams = [
            Task { [weak self] in
                for await snapshot in issues { self?.received(snapshot) }
            },
            Task { [weak self] in
                for await _ in geometry { self?.moved() }
            },
        ]
        monitor(.mouseMoved) { $0.pointerMoved() }
        monitor(.scrollWheel) { $0.moved() }
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
        streams.forEach { $0.cancel() }
        streams = []
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        dwell?.cancel()
        redraw?.cancel()
        hideMarks()
        cards.close()
        windows.forEach { $0.close() }
        windows = []
    }

    // MARK: Inputs

    private func received(_ new: IssueSnapshot) {
        generation += 1
        let fieldChanged = new.field != snapshot.field
        if fieldChanged { capabilities = nil }
        snapshot = new
        let visible = Set(new.issues.map(\.id))
        cards.retain { $0.survives(visible: visible, in: new.field) }
        if fieldChanged || new.issues.isEmpty { hideMarks() }
        requestRedraw()
    }

    /// A window moved, the caret moved or something scrolled: the words are elsewhere now, so a card that is
    /// only offering its choices closes, and the marks are read again.
    private func moved() {
        cards.retain { $0.phase != .ready }
        resetHover()
        requestRedraw()
    }

    private func pointerMoved() {
        let point = NSEvent.mouseLocation
        if let cardAnchor, !cards.isBusy, !cardAnchor.union(cards.frame).contains(point) {
            cards.close()
        }
        switch hover.pointer(at: point, over: targets) {
        case .unchanged: break
        case .entered(let id): wait(for: id)
        case .left: dwell?.cancel()
        }
    }

    /// A click in another app closes every card except one still applying its fix.
    private func clickedElsewhere() {
        cards.retain { $0.phase == .working }
        resetHover()
    }

    private func badgeClicked() {
        guard !cards.isBusy else { return }
        if cards.isOpen, cardAnchor == nil { return cards.close() }
        guard let frame = badge.frame, !snapshot.issues.isEmpty else { return }
        open(snapshot.issues.map(card), anchor: frame, hoverAnchor: nil)
    }

    // MARK: Cards

    private func wait(for id: UUID) {
        dwell?.cancel()
        let sleep = self.sleep
        dwell = Task { [weak self] in
            do { try await sleep(Self.hoverDelay) } catch { return }
            self?.rested(on: id)
        }
    }

    private func rested(on id: UUID) {
        guard hover.current == id, !cards.isBusy, !cards.cards.contains(where: { $0.id == id }),
              let issue = snapshot.issues.first(where: { $0.id == id }),
              let anchor = targets.first(where: { $0.id == id })?.rect
        else { return }
        open([card(issue)], anchor: anchor, hoverAnchor: anchor)
    }

    private func open(_ models: [IssueCardModel], anchor: CGRect, hoverAnchor: CGRect?) {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        cards.show(models, anchor: anchor, screen: screen?.visibleFrame ?? anchor)
        cardAnchor = hoverAnchor
    }

    private func card(_ issue: Issue) -> IssueCardModel {
        let writes = capabilities.map { $0.field == issue.key.field && $0.value.contains(.cleanWrite) } ?? false
        return IssueCardModel(
            issue: issue, writes: writes, clipboard: clipboard,
            actions: .init(
                accept: { [pipeline] id in await pipeline.accept(id) },
                ignore: { [pipeline] id in Task { await pipeline.ignore(id) } },
                neverFlag: { [weak self] id in self?.neverFlag(id) }
            )
        )
    }

    /// The pipeline drops every issue on the word; the settings model saves it and hands the new list on.
    private func neverFlag(_ id: UUID) {
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
        let generation = self.generation
        let snapshot = self.snapshot
        guard let field = snapshot.field, !snapshot.issues.isEmpty else { return hideMarks() }
        let capabilities = await capabilities(of: field)
        guard generation == self.generation else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

        if capabilities.contains(.rangeBounds) {
            let frame = await access.frame(of: field)
            var marks: [UnderlineView.Mark] = []
            var targets: [HoverTracker.Target] = []
            for issue in snapshot.issues.sorted(by: { $0.source == .model && $1.source != .model }) {
                guard let bounds = await access.bounds(OverlayGeometry.underlineRange(for: issue), in: field),
                      OverlayGeometry.isVisible(bounds, in: frame)
                else { continue }
                marks.append(.init(rect: OverlayGeometry.underline(for: bounds, primaryHeight: primaryHeight), source: issue.source))
                targets.append(.init(id: issue.id, rect: OverlayGeometry.appKit(bounds, primaryHeight: primaryHeight)))
            }
            guard generation == self.generation else { return }
            badge.hide()
            show(marks, targets: targets)
        } else if capabilities.contains(.fieldFrame), let frame = await access.frame(of: field) {
            guard generation == self.generation else { return }
            show([], targets: [])
            badge.show(count: snapshot.issues.count, at: OverlayGeometry.badgeFrame(for: frame, primaryHeight: primaryHeight))
        } else {
            hideMarks()
        }
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
        show([], targets: [])
        badge.hide()
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
