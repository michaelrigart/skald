import ApplicationServices
import SkaldCore
import struct SkaldCore.TextRange

/// How one field's text and selection are read, in UTF-16 offsets. Called on `AXQueue` only.
protocol FieldReader: Sendable {
    func length() -> Int?
    func selection() -> TextRange?
    /// The exact text of `range`, or nil when it can't be read.
    func string(for range: TextRange) -> String?
    func bounds(for range: TextRange) -> CGRect?
    /// Asks the app to select `range`; true when it accepted the call.
    func select(_ range: TextRange) -> Bool
}

/// A field read through Accessibility's character ranges, falling back to its whole value where ranged reads fail.
struct RangeReader: FieldReader {
    let element: AXElement

    /// A field qualifies when it has a selected range and its read window can be read.
    init?(_ element: AXElement) {
        self.element = element
        guard TextAccessRules.window(of: self) != nil else { return nil }
    }

    func length() -> Int? {
        element.numberOfCharacters
    }

    func selection() -> TextRange? {
        element.selectedRange.map { TextRange(location: $0.location, length: $0.length) }
    }

    func string(for range: TextRange) -> String? {
        TextAccessRules.read(
            range, ranged: { element.string(for: CFRange(range)) }, length: { element.numberOfCharacters }, value: { element.value }
        )
    }

    func bounds(for range: TextRange) -> CGRect? {
        element.bounds(for: CFRange(range)).flatMap { AXElement.usable($0) }
    }

    func select(_ range: TextRange) -> Bool {
        element.setSelectedRange(CFRange(range)) == .success
    }
}

extension CFRange {
    init(_ range: TextRange) {
        self.init(location: range.location, length: range.length)
    }
}
