public enum ReadWindow {
    /// The longest field read whole, in UTF-16 units; a longer one is read around the caret.
    public static let limit = 20_000

    public static func range(totalLength: Int, caret: Int, limit: Int = limit, radius: Int = 5_000) -> TextRange {
        guard totalLength > limit else { return TextRange(location: 0, length: totalLength) }
        let length = min(2 * radius, totalLength)
        let location = min(max(caret - radius, 0), totalLength - length)
        return TextRange(location: location, length: length)
    }
}
