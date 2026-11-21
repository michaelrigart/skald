import CoreGraphics
import Foundation
import SkaldCore

enum ScrollLag {
    /// Measured with `--probe-scroll`: the largest lag per app, rounded up to 50 ms. Only measured apps are
    /// here, by bundle id; an app that isn't keeps its underlines hidden after a scroll until the next text or
    /// caret change. None has been measured yet.
    static let ceilings: [String: Duration] = [:]

    static func ceiling(for bundleID: String) -> Duration? {
        ceilings[bundleID]
    }
}

/// Runs `ScrollSettle` for one field: a scroll hides the underlines and starts the reads, each read is a layout
/// taken `ceiling` after the last, and the underlines show again when `ScrollSettle` says the layouts agree.
/// No read is scheduled except by one of its actions, and none runs while nothing happens.
final class ScrollSettler<Layout> {
    private let sleep: (Duration) async throws -> Void
    private let now: () -> Duration
    private let layout: () async -> Layout
    private let rects: (Layout) -> [CGRect]
    private let hide: () -> Void
    private let show: (Layout) -> Void

    private var settle: ScrollSettle<[CGRect]>
    /// Bumped by every scroll and every redraw, so a read that started before one is dropped, not fed.
    private var epoch = 0
    private var pending: Task<Void, Never>?
    /// Bumped by every scroll, every redraw and every show: marks a pass read before it are stale after it.
    private(set) var drawEpoch = 0

    /// `now` is the time since one fixed instant on the clock `sleep` runs on.
    init(
        ceiling: Duration?, sleep: @escaping (Duration) async throws -> Void, now: @escaping () -> Duration,
        layout: @escaping () async -> Layout, rects: @escaping (Layout) -> [CGRect],
        hide: @escaping () -> Void, show: @escaping (Layout) -> Void
    ) {
        settle = ScrollSettle(ceiling: ceiling)
        self.sleep = sleep
        self.now = now
        self.layout = layout
        self.rects = rects
        self.hide = hide
        self.show = show
    }

    var isHidden: Bool { settle.isHidden }

    /// Whether a redraw pass that began at `epoch` may draw its marks: nothing is hidden, and no scroll, redraw
    /// or show has drawn since. A pass dropped this way is followed by one that draws.
    func mayDrawMarks(since epoch: Int) -> Bool {
        !isHidden && drawEpoch == epoch
    }

    func scrolled() {
        epoch += 1
        drawEpoch += 1
        pending?.cancel()
        pending = nil
        perform(settle.scrolled(at: now()), reading: nil)
    }

    /// A text or caret change drew the underlines again: nothing is pending any more.
    func redrawn() {
        epoch += 1
        drawEpoch += 1
        pending?.cancel()
        pending = nil
        settle.redrawn()
    }

    func cancel() {
        epoch += 1
        pending?.cancel()
        pending = nil
    }

    private func perform(_ actions: [ScrollSettle<[CGRect]>.Action], reading: Layout?) {
        for action in actions {
            switch action {
            case .hide: hide()
            case .read(let delay): read(after: delay)
            case .show:
                guard let reading else { break }
                drawEpoch += 1
                show(reading)
            }
        }
    }

    private func read(after delay: Duration) {
        let epoch = self.epoch
        let sleep = self.sleep
        pending = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, epoch == self.epoch else { return }
            let taken = self.now()
            let reading = await self.layout()
            guard epoch == self.epoch, !Task.isCancelled else { return }
            self.perform(self.settle.read(self.rects(reading), at: taken), reading: reading)
        }
    }
}
