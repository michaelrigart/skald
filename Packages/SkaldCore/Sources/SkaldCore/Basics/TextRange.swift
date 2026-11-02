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
