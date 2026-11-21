import Foundation
import SkaldCore
import Testing
@testable import Skald

private func segments(_ original: String, _ revised: String) -> [DiffText.Segment] {
    DiffText.segments(original: original, edits: TextDiff.edits(from: original, to: revised))
}

private func joined(_ segments: [DiffText.Segment], skipping kind: DiffText.Kind) -> String {
    segments.filter { $0.kind != kind }.map(\.text).joined()
}

struct DiffTextTests {
    @Test func aReplacedWordKeepsTheSpacesAroundItUnchanged() {
        #expect(segments("We flew to teh office", "We flew to the office") == [
            .init(text: "We flew to ", kind: .same), .init(text: "teh", kind: .removed),
            .init(text: "the", kind: .added), .init(text: " office", kind: .same),
        ])
    }

    @Test func anInsertedWordShowsOnlyTheWordAndItsOwnSpace() {
        #expect(segments("I have dog", "I have a dog") == [
            .init(text: "I have ", kind: .same), .init(text: "a ", kind: .added), .init(text: "dog", kind: .same),
        ])
    }

    @Test func aDeletedWordShowsOnlyTheWordAndItsOwnSpace() {
        #expect(segments("We really flew", "We flew") == [
            .init(text: "We ", kind: .same), .init(text: "really ", kind: .removed), .init(text: "flew", kind: .same),
        ])
    }

    @Test func theSegmentsRebuildBothTextsAcrossParagraphBreaks() {
        let original = "Teh cat\n\nsat on teh mat."
        let revised = "The cat\n\nsat on the mat!"
        let parts = segments(original, revised)
        #expect(joined(parts, skipping: .added) == original)
        #expect(joined(parts, skipping: .removed) == revised)
        #expect(parts.filter { $0.kind == .removed }.map(\.text) == ["Teh", "teh", "."])
    }

    @Test func noEditsIsTheOriginalUnchanged() {
        #expect(DiffText.segments(original: "Alles klopt.", edits: []) == [.init(text: "Alles klopt.", kind: .same)])
    }
}
