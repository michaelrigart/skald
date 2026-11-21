import Foundation

/// A range of UTF-16 code units, matching `NSRange` and Accessibility's `CFRange`.
public struct TextRange: Hashable, Codable, Sendable {
    public var location: Int
    public var length: Int
    public var end: Int { location + length }

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public init(_ range: NSRange) {
        self.init(location: range.location, length: range.length)
    }
}

extension String {
    /// True when both strings hold the same UTF-16 units. Swift's `==` is canonical equality, which calls "é" and
    /// "e" + U+0301 equal; text that is later written at UTF-16 offsets must be compared by its units.
    public func hasSameUTF16(as other: String) -> Bool {
        utf16.elementsEqual(other.utf16)
    }
}
