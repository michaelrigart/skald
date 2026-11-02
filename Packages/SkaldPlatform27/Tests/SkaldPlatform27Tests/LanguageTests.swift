import Foundation
import SkaldCore
import SkaldCoreTestSupport
import Testing
@testable import SkaldPlatform27

private let french = "Je viens de relire la documentation et je pense que tout est correct pour la mise en production demain."

struct SystemLanguageDetectorTests {
    @Test("The spike's English, Dutch and French sentences are recognised", .tags(.requiresSystem),
          arguments: [(spike["en1"]!.text, Language.en), (spike["nl1"]!.text, .nl), (french, .fr)])
    func recognisesTheThreeLanguages(_ sample: (String, Language)) {
        #expect(SystemLanguageDetector().detect(sample.0, previous: nil) == sample.1)
    }

    @Test("Text under 20 UTF-16 units inherits the previous language", .tags(.requiresSystem))
    func shortTextInherits() {
        let detector = SystemLanguageDetector()
        #expect(detector.detect("ok", previous: .nl) == .nl)
        #expect(detector.detect("ok", previous: nil) == nil)
    }

    @Test("Text that no language reaches 0.6 for returns the previous language", .tags(.requiresSystem))
    func unclearTextInherits() {
        let detector = SystemLanguageDetector()
        #expect(detector.detect("1234567890 1234567890 1234567890", previous: .fr) == .fr)
    }

    @Test("A language outside English, Dutch and French is never returned", .tags(.requiresSystem))
    func otherLanguagesAreIgnored() {
        let german = "Ich habe die Dokumentation gelesen und denke, dass alles für den Einsatz morgen bereit ist."
        let detected = SystemLanguageDetector().detect(german, previous: .en)
        #expect(detected == .en || detected == .nl)
    }
}

struct SystemWordOracleTests {
    @Test("English holds a word only when both dictionaries flag it", .tags(.requiresSystem))
    func englishMisspelledNeedsBothDictionaries() async {
        let facts = await SystemWordOracle().facts(for: ["colour", "color", "recieve"], language: .en)
        #expect(facts.misspelled == ["recieve"])
        #expect(facts.english.isSuperset(of: ["colour", "color"]))
        #expect(!facts.english.contains("recieve"))
    }

    @Test("Dutch and French use their own dictionaries", .tags(.requiresSystem))
    func dutchAndFrenchDictionaries() async {
        let nl = await SystemWordOracle().facts(for: ["eigelijk", "onmiddelijk", "reviewt"], language: .nl)
        #expect(nl.misspelled == ["onmiddelijk", "reviewt"])
        let fr = await SystemWordOracle().facts(for: ["mergé", "deja", "déjà"], language: .fr)
        #expect(fr.misspelled == ["mergé", "deja"])
    }

    @Test("Dutch and French suffixes are stripped to an accepted English stem", .tags(.requiresSystem))
    func englishStems() async {
        let oracle = SystemWordOracle()
        let nl = await oracle.facts(for: ["reviewt", "gemerged", "wordt", "gedownloaded"], language: .nl)
        #expect(nl.englishStems["reviewt"] == "review")
        #expect(nl.englishStems["gemerged"] == "merge")
        #expect(nl.englishStems["gedownloaded"] == nil)
        let fr = await oracle.facts(for: ["mergé"], language: .fr)
        #expect(fr.englishStems["mergé"] == "merge")
        let en = await oracle.facts(for: ["reviewt"], language: .en)
        #expect(en.englishStems.isEmpty)
    }

    @Test("Lemmas come from NaturalLanguage for English and French, never Dutch", .tags(.requiresSystem))
    func lemmas() async {
        let oracle = SystemWordOracle()
        let en = await oracle.facts(for: ["went", "walked"], language: .en)
        #expect(en.lemmas["went"] == "go")
        #expect(en.lemmas["walked"] == "walk")
        let fr = await oracle.facts(for: ["sont"], language: .fr)
        #expect(fr.lemmas["sont"] == "être")
        let nl = await oracle.facts(for: ["gebeurt", "gebeurd"], language: .nl)
        #expect(nl.lemmas.isEmpty)
    }

    @Test("Function words are the listed ones plus pronouns, conjunctions and particles only", .tags(.requiresSystem))
    func functionWords() async {
        let oracle = SystemWordOracle()
        let en = await oracle.facts(for: ["the", "and", "all", "some", "afterwards", "tegen"], language: .en)
        #expect(en.functionWords.isSuperset(of: ["the", "and"]))
        #expect(en.functionWords.isDisjoint(with: ["all", "some", "afterwards", "tegen"]))
        let nl = await oracle.facts(for: ["de", "wel", "niet"], language: .nl)
        #expect(nl.functionWords == ["de"])
    }

    @Test("A request answers only for the words it was given", .tags(.requiresSystem))
    func answersOnlyForRequestedWords() async {
        let words: Set<String> = ["recieve", "the"]
        let facts = await SystemWordOracle().facts(for: words, language: .en)
        #expect(facts.misspelled.isSubset(of: words))
        #expect(facts.english.isSubset(of: words))
        #expect(facts.functionWords.isSubset(of: words))
        #expect(Set(facts.lemmas.keys).isSubset(of: words))
        #expect(await SystemWordOracle().facts(for: [], language: .en) == WordFacts())
    }
}
