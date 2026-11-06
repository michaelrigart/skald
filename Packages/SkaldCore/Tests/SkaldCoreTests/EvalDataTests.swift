import CryptoKit
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

/// SHA-256 digests of the real company names that must never appear, lowercased without spaces, with their
/// lengths in UTF-8 bytes, so this file doesn't name them either.
private let companyDigests: [(length: Int, digest: String)] = [
    (8, "0000000000000000000000000000000000000000000000000000000000000000"),
    (7, "0000000000000000000000000000000000000000000000000000000000000000"),
]

private func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// True when the text, lowercased without spaces, holds a stretch whose digest is listed.
private func contains(_ text: String, anyOf digests: [(length: Int, digest: String)]) -> Bool {
    let bytes = Array(text.lowercased().filter { !$0.isWhitespace }.utf8)
    return digests.contains { length, digest in
        let target = stride(from: 0, to: digest.count, by: 2).map { offset -> UInt8 in
            let start = digest.index(digest.startIndex, offsetBy: offset)
            return UInt8(digest[start..<digest.index(start, offsetBy: 2)], radix: 16)!
        }
        return bytes.count >= length && bytes.withUnsafeBufferPointer { buffer in
            (0...(bytes.count - length)).contains { SHA256.hash(data: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: buffer[$0..<($0 + length)]))).elementsEqual(target) }
        }
    }
}

@Test func theDigestCheckFindsANameInsideText() {
    let fictional = [(length: 10, digest: sha256("brightline"))]
    #expect(contains("We met the Bright line team today.", anyOf: fictional))
    #expect(!contains("We met the Northwind team today.", anyOf: fictional))
}

@Test func noCaseNamesARealCompany() throws {
    let named = try allCases().filter { contains($0.text, anyOf: companyDigests) || contains($0.ref, anyOf: companyDigests) }
    #expect(named.isEmpty, "cases naming a real company: \(named.map(\.id))")
}

/// Every tracked text file: the repository without what is generated or never committed.
private func trackedTextFiles() -> [URL] {
    let root = evalDirectory.deletingLastPathComponent()
    let skipped: Set<String> = [".git", ".build", "build", ".superpowers", ".swiftpm", "Skald.xcodeproj"]
    let extensions: Set<String> = ["swift", "md", "json", "jsonl", "yml", "yaml", "toml", "plist", "entitlements", "txt"]
    guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    var files: [URL] = []
    for case let url as URL in walk {
        if skipped.contains(url.lastPathComponent) {
            walk.skipDescendants()
        } else if extensions.contains(url.pathExtension) {
            files.append(url)
        }
    }
    return files
}

@Test func noTrackedFileNamesARealCompany() throws {
    let files = trackedTextFiles()
    #expect(files.count > 100)
    let named = try files.filter { contains(try String(contentsOf: $0, encoding: .utf8), anyOf: companyDigests) }
    #expect(named.isEmpty, "files naming a real company: \(named.map(\.lastPathComponent))")
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
