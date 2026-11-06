public enum PanelText {
    public static func paragraphs(_ selection: String) -> [(text: String, separator: String)] {
        let scalars = Array(selection.unicodeScalars)
        var parts: [(text: String, separator: String)] = []
        var index = 0
        while index < scalars.count {
            let leadingEnd = blankRunEnd(from: index, in: scalars)
            let textEnd = leadingEnd > index ? index : skip(from: index, in: scalars) { !isBreak($0) }
            let separatorEnd = blankRunEnd(from: textEnd, in: scalars)
            parts.append((string(scalars[index..<textEnd]), string(scalars[textEnd..<separatorEnd])))
            index = separatorEnd
        }
        return parts
    }

    public static func reassemble(_ parts: [(text: String, separator: String)]) -> String {
        parts.reduce(into: "") { $0 += $1.text + $1.separator }
    }

    private static func isBreak(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value <= 0xFFFF && Paragraphs.isLineBreak(UInt16(scalar.value))
    }

    private static func isBlank(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace && !isBreak(scalar)
    }

    private static func skip(from start: Int, in scalars: [Unicode.Scalar], while predicate: (Unicode.Scalar) -> Bool) -> Int {
        var index = start
        while index < scalars.count, predicate(scalars[index]) { index += 1 }
        return index
    }

    private static func blankRunEnd(from start: Int, in scalars: [Unicode.Scalar]) -> Int {
        var end = start
        while true {
            let lineEnd = skip(from: end, in: scalars, while: isBlank)
            if lineEnd == scalars.count { return lineEnd }
            guard isBreak(scalars[lineEnd]) else { return end }
            end = skip(from: lineEnd, in: scalars, while: isBreak)
        }
    }

    private static func string(_ slice: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: slice)
        return String(view)
    }
}
