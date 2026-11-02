import AppKit

enum FormattingFingerprint {
    struct Run: Equatable {
        var length: Int
        var bold = false
        var italic = false
        var underline = false
        var strikethrough = false
        var colour: String?
        var link = false
    }

    private static let font = NSAttributedString.Key("AXFont")
    private static let underline = NSAttributedString.Key("AXUnderline")
    private static let strikethrough = NSAttributedString.Key("AXStrikethrough")
    private static let colour = NSAttributedString.Key("AXForegroundColor")
    private static let link = NSAttributedString.Key("AXLink")

    static func kept(before: NSAttributedString, after: NSAttributedString) -> Bool {
        runs(of: before) == runs(of: after)
    }

    static func runs(of text: NSAttributedString) -> [Run] {
        var runs: [Run] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var run = signature(of: attributes)
            run.length = range.length
            if var last = runs.last, last.sameFormatting(as: run) {
                last.length += run.length
                runs[runs.count - 1] = last
            } else {
                runs.append(run)
            }
        }
        return runs
    }

    private static func signature(of attributes: [NSAttributedString.Key: Any]) -> Run {
        var run = Run(length: 0)
        for candidate in [attributes[.font], attributes[font]] {
            if let nsFont = candidate as? NSFont {
                let traits = nsFont.fontDescriptor.symbolicTraits
                run.bold = run.bold || traits.contains(.bold)
                run.italic = run.italic || traits.contains(.italic)
            } else if let dictionary = candidate as? [String: Any], let name = dictionary["AXFontName"] as? String {
                let lowered = name.lowercased()
                run.bold = run.bold || lowered.contains("bold")
                run.italic = run.italic || lowered.contains("italic") || lowered.contains("oblique")
            }
        }
        run.underline = isOn(attributes[.underlineStyle]) || isOn(attributes[underline])
        run.strikethrough = isOn(attributes[.strikethroughStyle]) || isOn(attributes[strikethrough])
        run.colour = (attributes[.foregroundColor] ?? attributes[colour]).map { String(describing: $0) }
        run.link = attributes[.link] != nil || attributes[link] != nil
        return run
    }

    private static func isOn(_ value: Any?) -> Bool {
        switch value {
        case let number as NSNumber: number.intValue != 0
        case let text as String: !text.isEmpty
        case .some: true
        case .none: false
        }
    }
}

private extension FormattingFingerprint.Run {
    func sameFormatting(as other: Self) -> Bool {
        var copy = other
        copy.length = length
        return copy == self
    }
}
