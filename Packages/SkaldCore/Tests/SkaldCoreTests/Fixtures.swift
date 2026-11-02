import Foundation

enum Fixtures {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
            .appending(path: "spike/\(name).jsonl")
    }

    static var wordFacts: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
            .appending(path: "guard/word-facts.json")
    }
}
