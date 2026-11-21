import CoreGraphics
import Foundation

public enum ScrollKind: String, Sendable, CaseIterable {
    case wheel, trackpad, momentum
}

/// One gesture: scroll events and bounds samples in time order, times from the probe's start.
public struct ScrollLagTrace: Sendable {
    /// No change and no scroll for this long: settled.
    public static let quiet: Duration = .seconds(1)
    /// After the last scroll event: unsettled.
    public static let giveUp: Duration = .seconds(5)
    /// One more sample, 3 s after the last scroll event: bounds that differ from the settled ones mean the app
    /// caught up late, and the gesture counts as unsettled.
    public static let finalCheck: Duration = .seconds(3)

    private var lastScroll: Duration?
    private var lastChange: Duration?
    private var latest: Duration = .zero
    private var previous: CGRect?
    private var sawBoundsSinceScroll = false
    private var caughtUpLate = false

    public init() {}

    /// The last event's kind.
    public private(set) var kind: ScrollKind?

    public mutating func scrolled(_ kind: ScrollKind, at now: Duration) {
        self.kind = kind
        lastScroll = now
        latest = max(latest, now)
        sawBoundsSinceScroll = false
    }

    public mutating func sampled(_ bounds: CGRect?, at now: Duration) {
        latest = max(latest, now)
        guard let bounds else { return }
        if let previous, previous != bounds { lastChange = now }
        previous = bounds
        if lastScroll != nil { sawBoundsSinceScroll = true }
    }

    /// From the last scroll event to the last sample that differed from the one before it; zero when none did.
    /// Nil before any scroll, and when no sample since the last scroll had bounds.
    public var lag: Duration? {
        guard let lastScroll, sawBoundsSinceScroll else { return nil }
        guard let lastChange, lastChange >= lastScroll else { return .zero }
        return lastChange - lastScroll
    }

    public func isSettled(at now: Duration) -> Bool {
        guard let lastScroll else { return false }
        return now - max(lastScroll, lastChange ?? lastScroll) >= Self.quiet
    }

    public func gaveUp(at now: Duration) -> Bool {
        guard let lastScroll else { return false }
        return now - lastScroll >= Self.giveUp
    }

    public mutating func checkedFinally(_ bounds: CGRect?) {
        guard let bounds, let previous, bounds != previous else { return }
        caughtUpLate = true
    }

    /// Gave up, or the final check differed.
    public var isUnsettled: Bool {
        caughtUpLate || gaveUp(at: latest)
    }
}

public enum ScrollLagSummary {
    public static let gestures = 20
    private static let step: Duration = .milliseconds(50)

    /// Nil with fewer than `gestures` lags or any nil (unsettled) among them; else the largest, up to the next
    /// 50 ms, at least 50 ms.
    public static func ceiling(_ lags: [Duration?]) -> Duration? {
        guard lags.count >= gestures else { return nil }
        let settled = lags.compactMap { $0 }
        guard settled.count == lags.count, let largest = settled.max() else { return nil }
        let steps = Int((largest / step).rounded(.up))
        return step * max(steps, 1)
    }

    /// The app's ceiling: the largest of its kinds', nil when any kind has none.
    public static func ceiling(byKind: [ScrollKind: [Duration?]]) -> Duration? {
        let ceilings = ScrollKind.allCases.map { kind in byKind[kind].flatMap { ceiling($0) } }
        guard ceilings.allSatisfy({ $0 != nil }) else { return nil }
        return ceilings.compactMap { $0 }.max()
    }

    /// Per bundle id: the lags in ms per kind (null for unsettled) and the app's ceiling in ms or null. App
    /// identifiers, kinds and milliseconds only.
    public static func json(byApp: [String: [ScrollKind: [Duration?]]]) -> Data {
        let apps = byApp.mapValues { byKind in
            AppEntry(
                lagsMs: Dictionary(uniqueKeysWithValues: byKind.map { kind, lags in (kind.rawValue, lags.map { $0.map(milliseconds) }) }),
                ceilingMs: ceiling(byKind: byKind).map(milliseconds)
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? encoder.encode(apps)) ?? Data("{}".utf8)
    }

    private struct AppEntry: Encodable {
        let lagsMs: [String: [Int?]]
        let ceilingMs: Int?

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(lagsMs, forKey: .lagsMs)
            try container.encode(ceilingMs, forKey: .ceilingMs)
        }

        private enum CodingKeys: String, CodingKey { case lagsMs, ceilingMs }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int((duration / .milliseconds(1)).rounded())
    }
}
