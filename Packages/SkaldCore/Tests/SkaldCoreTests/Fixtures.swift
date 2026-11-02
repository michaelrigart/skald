import Foundation

enum Fixtures {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
            .appending(path: "spike/\(name).jsonl")
    }
}
