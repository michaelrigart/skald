import AppKit
import Testing
@testable import SkaldPlatform27

private func text(_ attributes: [NSAttributedString.Key: Any], _ more: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
    let result = NSMutableAttributedString(string: "Hello ther", attributes: attributes)
    if !more.isEmpty { result.addAttributes(more, range: NSRange(location: 6, length: 4)) }
    return result
}

private var regular: NSFont { NSFont.systemFont(ofSize: 12) }
private var bold: NSFont { NSFont.boldSystemFont(ofSize: 12) }

@Test func asynchronousSpellingMarksDoNotCountAsLostFormatting() {
    let before = text([.font: bold])
    let after = text([.font: bold], [NSAttributedString.Key("AXMarkedMisspelled"): true])
    #expect(!before.isEqual(to: after))
    #expect(FormattingFingerprint.kept(before: before, after: after))
}

@Test func losingBoldCountsAsLostFormatting() {
    #expect(!FormattingFingerprint.kept(before: text([.font: bold]), after: text([.font: regular])))
}

@Test func underlineStrikethroughColourAndLinkAreFormatting() {
    let plain = text([.font: regular])
    #expect(!FormattingFingerprint.kept(before: plain, after: text([.font: regular], [.underlineStyle: 1])))
    #expect(!FormattingFingerprint.kept(before: plain, after: text([.font: regular], [.strikethroughStyle: 1])))
    #expect(!FormattingFingerprint.kept(before: plain, after: text([.font: regular], [.foregroundColor: NSColor.red])))
    #expect(!FormattingFingerprint.kept(before: plain, after: text([.font: regular], [.link: "https://example.com"])))
}

@Test func accessibilityFontDictionariesAreReadByName() {
    let boldName: [String: Any] = ["AXFontName": "Helvetica-Bold"]
    let regularName: [String: Any] = ["AXFontName": "Helvetica"]
    let key = NSAttributedString.Key("AXFont")
    #expect(!FormattingFingerprint.kept(before: text([key: boldName]), after: text([key: regularName])))
    #expect(FormattingFingerprint.kept(before: text([key: boldName]), after: text([key: boldName])))
}
