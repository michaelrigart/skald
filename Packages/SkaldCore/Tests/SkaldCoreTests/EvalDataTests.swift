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

/// Names no tracked file may contain, one per line, from an untracked list on this Mac:
/// `$XDG_CONFIG_HOME/skald/forbidden-names`, else `~/.config/skald/forbidden-names`. Nil without the list,
/// and the checks that need it are skipped.
private let forbiddenNames: [String]? = {
    let environment = ProcessInfo.processInfo.environment
    let config = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
    guard let list = try? String(contentsOf: config.appending(path: "skald/forbidden-names"), encoding: .utf8) else { return nil }
    let names = list.split(whereSeparator: \.isNewline).map(squeezed).filter { !$0.isEmpty }
    return names.isEmpty ? nil : names
}()

/// Lowercased without whitespace, so "A B" also matches "ab" and "a b".
private func squeezed<S: StringProtocol>(_ text: S) -> String {
    text.lowercased().filter { !$0.isWhitespace }
}

private func contains(_ text: String, anyOf names: [String]) -> Bool {
    let text = squeezed(text)
    return names.contains { text.contains($0) }
}

@Test func theNameCheckFindsANameInsideText() {
    let fictional = [squeezed("Bright Line")]
    #expect(contains("We met the Brightline team today.", anyOf: fictional))
    #expect(!contains("We met the Northwind team today.", anyOf: fictional))
}

@Test(.enabled(if: forbiddenNames != nil, "no forbidden-names list on this Mac"))
func noCaseNamesARealCompany() throws {
    let names = try #require(forbiddenNames)
    let named = try allCases().filter { contains($0.text, anyOf: names) || contains($0.ref, anyOf: names) }
    #expect(named.isEmpty, "cases naming a real company: \(named.map(\.id))")
}

/// Every file git tracks, as paths relative to the repository's root.
private func trackedFiles(in root: URL) throws -> [String] {
    let git = Process()
    git.executableURL = URL(filePath: "/usr/bin/git")
    git.arguments = ["-C", root.path, "ls-files", "-z"]
    let output = Pipe()
    git.standardOutput = output
    try git.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    git.waitUntilExit()
    guard git.terminationStatus == 0 else { return [] }
    return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
}

/// Every tracked file that reads as UTF-8 text, whatever its extension.
@Test(.enabled(if: forbiddenNames != nil, "no forbidden-names list on this Mac"))
func noTrackedFileNamesARealCompany() throws {
    let names = try #require(forbiddenNames)
    let root = evalDirectory.deletingLastPathComponent()
    let files = try trackedFiles(in: root)
    #expect(files.count > 100)
    let named = files.filter { path in
        guard let text = try? String(contentsOf: root.appending(path: path), encoding: .utf8) else { return false }
        return contains(text, anyOf: names)
    }
    #expect(named.isEmpty, "tracked files naming a real company: \(named)")
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
