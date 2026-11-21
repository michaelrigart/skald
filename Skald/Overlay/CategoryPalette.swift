import AppKit
import SkaldCore

/// One colour per category for both appearances: the text under an underline follows the page or the app,
/// not the system. Punctuation is also dotted, a second cue on a 2-point line.
enum CategoryPalette {
    struct RGB: Equatable {
        let red, green, blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init(hex: UInt32) {
            self.init(
                red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255
            )
        }
    }

    static func rgb(_ category: IssueCategory) -> RGB {
        switch category {
        case .spelling: RGB(hex: 0xD55E00)
        case .grammar: RGB(hex: 0x0072B2)
        case .punctuation: RGB(hex: 0x8B5CF6)
        }
    }

    static func color(_ category: IssueCategory) -> NSColor {
        let value = rgb(category)
        return NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: 1)
    }

    static func isDotted(_ category: IssueCategory) -> Bool {
        category == .punctuation
    }
}
