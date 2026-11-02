import Foundation
import Testing
@testable import SkaldCore

private let evalDirectory = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Eval")

private let files = ["seed", "tuning", "heldout"]

private func url(_ name: String) -> URL {
    evalDirectory.appending(path: "\(name).jsonl")
}

private func cases(_ name: String) throws -> [EvalCase] {
    try EvalScorer.loadJSONL(url(name))
}

private func allCases() throws -> [EvalCase] {
    try files.flatMap(cases)
}

@Test(arguments: files)
private func everyFileDecodes(_ name: String) throws {
    #expect(try !cases(name).isEmpty)
}

@Test func evalCaseDecodingIgnoresUnknownKeys() throws {
    let line = #"{"id":"x1","lang":"nl","text":"Dag Jan.","ref":"Dag Jan.","reviewed":false}"#
    let decoded = try JSONDecoder().decode(EvalCase.self, from: Data(line.utf8))
    #expect((decoded.id, decoded.lang, decoded.text, decoded.ref) == ("x1", .nl, "Dag Jan.", "Dag Jan."))
}

@Test func idsAreUniqueAcrossFiles() throws {
    let ids = try allCases().map(\.id)
    let duplicates = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
    #expect(duplicates.isEmpty, "duplicate ids: \(duplicates)")
}

private func normalised(_ text: String) -> String {
    text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

@Test func heldOutCasesNeverAppearInTheTuningPart() throws {
    let tuning = try cases("seed") + cases("tuning")
    let ids = Set(tuning.map(\.id)), texts = Set(tuning.map { normalised($0.text) })
    let leaked = try cases("heldout").filter { ids.contains($0.id) || texts.contains(normalised($0.text)) }.map(\.id)
    #expect(leaked.isEmpty, "held-out cases in the tuning part: \(leaked)")
}

@Test(arguments: Language.allCases)
private func eachLanguageHasFiftyCasesAThirdOfThemClean(_ language: Language) throws {
    let own = try allCases().filter { $0.lang == language }
    let clean = own.filter { $0.text == $0.ref }.count
    #expect(own.count >= 50, "\(language): \(own.count) cases")
    #expect(clean * 3 >= own.count, "\(language): \(clean) of \(own.count) clean")
}

@Test func noCaseNamesARealCompany() throws {
    let named = try allCases().filter { c in
        let squeezed = [c.text, c.ref].map { $0.lowercased().filter { !$0.isWhitespace } }
        return ["redacted", "redacted"].contains { name in squeezed.contains { $0.contains(name) } }
    }
    #expect(named.isEmpty, "cases naming a real company: \(named.map(\.id))")
}

@Test(arguments: ["tuning", "heldout"])
private func everyNewCaseCarriesAReviewedFlag(_ name: String) throws {
    let lines = try String(contentsOf: url(name), encoding: .utf8).split(whereSeparator: \.isNewline)
    let unflagged = try lines.compactMap { line -> String? in
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        return object["reviewed"] is Bool ? nil : object["id"] as? String ?? String(line)
    }
    #expect(unflagged.isEmpty, "cases without a reviewed flag: \(unflagged)")
}

@Test func everyCaseFitsInOneModelRequest() throws {
    let long = try allCases().filter { $0.text.utf16.count > 1_200 }
    #expect(long.isEmpty, "cases over the 1,200-unit chunk limit: \(long.map(\.id))")
}
