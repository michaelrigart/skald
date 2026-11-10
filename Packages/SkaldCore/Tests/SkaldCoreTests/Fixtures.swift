import Foundation
import SkaldCoreTestSupport

enum Fixtures {
    static func url(_ name: String) -> URL {
        SpikeFixtures.url(name)
    }

    static var wordFacts: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
            .appending(path: "guard/word-facts.json")
    }
}
