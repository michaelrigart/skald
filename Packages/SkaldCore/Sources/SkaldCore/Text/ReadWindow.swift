public enum ReadWindow {
    public static func range(totalLength: Int, caret: Int, limit: Int = 20_000, radius: Int = 5_000) -> TextRange {
        guard totalLength > limit else { return TextRange(location: 0, length: totalLength) }
        let length = min(2 * radius, totalLength)
        let location = min(max(caret - radius, 0), totalLength - length)
        return TextRange(location: location, length: length)
    }
}
