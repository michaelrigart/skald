import Foundation
import SkaldCore
import SwiftUI

/// The panel's result as a diff against the original: unchanged text as it was, removed text struck
/// through, added text highlighted. Each edit's splice is shown without the whitespace both sides share.
enum DiffText {
    enum Kind: Equatable {
        case same, removed, added
    }

    struct Segment: Equatable {
        let text: String
        let kind: Kind
    }

    static func segments(original: String, edits: [Edit]) -> [Segment] {
        let units = Array(original.utf16)
        var segments: [Segment] = []
        func append(_ slice: ArraySlice<UInt16>, _ kind: Kind) {
            guard !slice.isEmpty else { return }
            let text = String(decoding: slice, as: UTF16.self)
            if kind == .same, let last = segments.last, last.kind == .same {
                segments[segments.count - 1] = Segment(text: last.text + text, kind: .same)
            } else {
                segments.append(Segment(text: text, kind: kind))
            }
        }

        var cursor = 0
        for edit in edits.sorted(by: { $0.spliceRange.location < $1.spliceRange.location }) {
            let splice = edit.spliceRange
            guard splice.location >= cursor, splice.end <= units.count else { continue }
            append(units[cursor..<splice.location], .same)
            let removed = units[splice.location..<splice.end]
            let added = Array(edit.spliceText.utf16)[...]
            let lead = sharedWhitespace(removed, added, fromStart: true)
            let trail = sharedWhitespace(removed.dropFirst(lead), added.dropFirst(lead), fromStart: false)
            append(removed.prefix(lead), .same)
            append(removed.dropFirst(lead).dropLast(trail), .removed)
            append(added.dropFirst(lead).dropLast(trail), .added)
            append(removed.suffix(trail), .same)
            cursor = splice.end
        }
        append(units[cursor...], .same)
        return segments
    }

    static func attributed(original: String, edits: [Edit]) -> AttributedString {
        segments(original: original, edits: edits).reduce(into: AttributedString()) { text, segment in
            var part = AttributedString(segment.text)
            switch segment.kind {
            case .same:
                break
            case .removed:
                part.strikethroughStyle = .single
                part.foregroundColor = .secondary
            case .added:
                part.foregroundColor = .accentColor
                part.inlinePresentationIntent = .stronglyEmphasized
            }
            text += part
        }
    }

    private static func sharedWhitespace(_ a: ArraySlice<UInt16>, _ b: ArraySlice<UInt16>, fromStart: Bool) -> Int {
        let pairs = fromStart ? Array(zip(a, b)) : Array(zip(a.reversed(), b.reversed()))
        return pairs.prefix { $0 == $1 && isWhitespace($0) }.count
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        Unicode.Scalar(unit)?.properties.isWhitespace ?? false
    }
}
