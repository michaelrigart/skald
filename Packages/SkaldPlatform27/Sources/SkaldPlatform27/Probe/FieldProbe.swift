import ApplicationServices
import Foundation

enum ProbeMarker {
    static let pending = "~skald-probe~"
    static let replacement = "~skald-ok~"
    static let earlierWord = "alpha"
}

struct BoundsBaseline: Sendable, Equatable {
    var length: Int
    var location: Int
    var rangeLength: Int
    var bounds: CGRect
    var windowOrigin: CGPoint?

    var range: CFRange { CFRange(location: location, length: rangeLength) }
}

enum RecheckKind: Sendable, Equatable {
    case windowMoved, scrolled
}

enum BoundsComparison {
    static let tolerance: CGFloat = 2

    static func isStable(_ kind: RecheckKind, old: BoundsBaseline, bounds: CGRect?, windowOrigin: CGPoint?) -> Bool {
        guard let bounds else { return false }
        switch kind {
        case .scrolled:
            return true
        case .windowMoved:
            guard let before = old.windowOrigin, let after = windowOrigin else { return false }
            let driftX = (bounds.minX - old.bounds.minX) - (after.x - before.x)
            let driftY = (bounds.minY - old.bounds.minY) - (after.y - before.y)
            return abs(driftX) <= tolerance && abs(driftY) <= tolerance
        }
    }
}

struct AttributedSnapshot: @unchecked Sendable { // reason: an immutable value, only compared
    let value: NSAttributedString
}

struct FieldReading: Sendable {
    var identity: String
    var role: String
    var subrole: String
    var value: String?
    var canRead = false
    var rangedRead = false
    var canReadSelection = false
    var hasFrame = false
    var baseline: BoundsBaseline?
    var formatted: AttributedSnapshot?

    var isSecure: Bool { role == ProbeLine.secureRole || subrole == ProbeLine.secureRole }
}

struct WriteStart: Sendable {
    var original: String
    var before: AttributedSnapshot?
    var beforeLocation: Int
    var beforeLength: Int

    var expectedAfterWrite: String {
        String(original.dropLast(ProbeMarker.pending.count)) + ProbeMarker.replacement
    }

    var hadEarlierWord: Bool {
        original.range(of: ProbeMarker.earlierWord, options: .caseInsensitive) != nil
    }
}

enum WriteAttempt: Sendable {
    case started(WriteStart)
    case aborted(reason: String)
}

enum BoundsRecheck: Sendable {
    case skipped
    case result(stable: Bool, baseline: BoundsBaseline?)
}

enum FieldProbe {
    static let middleLength = 5
    static let contextLength = 10

    static func measure(pid: pid_t, formatting: (location: Int, length: Int)?) -> FieldReading? {
        guard let field = AXElement.focused(inApp: pid) else { return nil }
        var reading = FieldReading(identity: field.identity, role: field.role ?? "", subrole: field.subrole ?? "")
        if reading.isSecure { return reading }

        reading.value = field.value
        reading.canRead = reading.value != nil
        reading.canReadSelection = field.selectedRange != nil
        reading.hasFrame = field.frame.flatMap { usable($0) } != nil
        if let length = length(of: field, value: reading.value), length >= middleLength {
            let range = CFRange(location: max(0, length / 2 - middleLength / 2), length: middleLength)
            reading.rangedRead = field.string(for: range).map { ranged($0, matches: reading.value, at: range) } ?? false
            reading.baseline = baseline(of: field, length: length, range: range)
        }
        if let formatting {
            reading.formatted = field.attributedString(for: CFRange(location: formatting.location, length: formatting.length))
                .map(AttributedSnapshot.init)
        }
        return reading
    }

    static func write(pid: pid_t) -> WriteAttempt? {
        guard let field = AXElement.focused(inApp: pid), !isSecure(field),
              let value = field.value, value.hasSuffix(ProbeMarker.pending)
        else { return nil }
        let markerLength = (ProbeMarker.pending as NSString).length
        let markerLocation = (value as NSString).length - markerLength
        let beforeLocation = max(0, markerLocation - contextLength)
        let beforeLength = markerLocation - beforeLocation
        let before = beforeLength > 0
            ? field.attributedString(for: CFRange(location: beforeLocation, length: beforeLength)).map(AttributedSnapshot.init)
            : nil
        let markerRange = CFRange(location: markerLocation, length: markerLength)
        guard field.setSelectedRange(markerRange) == .success else { return .aborted(reason: "selection rejected") }
        guard selectionIsMarker(field, markerRange) else { return .aborted(reason: "selection does not cover the marker") }
        _ = field.setSelectedText(ProbeMarker.replacement)
        return .started(WriteStart(
            original: value, before: before, beforeLocation: beforeLocation, beforeLength: beforeLength
        ))
    }

    static func recheck(pid: pid_t, baseline: BoundsBaseline, kind: RecheckKind) -> BoundsRecheck {
        guard let field = AXElement.focused(inApp: pid), !isSecure(field),
              length(of: field, value: nil) == baseline.length
        else { return .skipped }
        let bounds = field.bounds(for: baseline.range).flatMap { usable($0) }
        let windowOrigin = field.window?.position
        let stable = BoundsComparison.isStable(kind, old: baseline, bounds: bounds, windowOrigin: windowOrigin)
        var updated = baseline
        if let bounds {
            updated.bounds = bounds
            updated.windowOrigin = windowOrigin
        }
        return .result(stable: stable, baseline: bounds == nil ? nil : updated)
    }

    static func isSecure(_ field: AXElement) -> Bool {
        field.role == ProbeLine.secureRole || field.subrole == ProbeLine.secureRole
    }

    private static func selectionIsMarker(_ field: AXElement, _ markerRange: CFRange) -> Bool {
        if let selectedText = field.selectedText { return selectedText == ProbeMarker.pending }
        guard let selected = field.selectedRange else { return false }
        return selected.location == markerRange.location && selected.length == markerRange.length
            && field.string(for: markerRange) == ProbeMarker.pending
    }

    private static func length(of field: AXElement, value: String?) -> Int? {
        field.numberOfCharacters ?? (value ?? field.value).map { ($0 as NSString).length }
    }

    private static func ranged(_ text: String, matches value: String?, at range: CFRange) -> Bool {
        guard let value, (value as NSString).length >= range.location + range.length else { return !text.isEmpty }
        return (value as NSString).substring(with: NSRange(location: range.location, length: range.length)) == text
    }

    private static func baseline(of field: AXElement, length: Int, range: CFRange) -> BoundsBaseline? {
        guard let bounds = field.bounds(for: range).flatMap({ usable($0) }) else { return nil }
        return BoundsBaseline(
            length: length, location: range.location, rangeLength: range.length,
            bounds: bounds, windowOrigin: field.window?.position
        )
    }

    private static func usable(_ rect: CGRect) -> CGRect? {
        rect.isNull || rect.isInfinite || rect.width <= 0 || rect.height <= 0 ? nil : rect
    }
}
