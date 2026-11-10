import Foundation
import SkaldCore
import SkaldCoreTestSupport
import Testing
@testable import SkaldPlatform27

struct SystemLanguageDetectorTests {
    @Test("The spike's English, Dutch and French sentences are recognised", .tags(.requiresSystem),
          arguments: [(spike["en1"]!.text, Language.en), (spike["nl1"]!.text, .nl), (spike["fr1"]!.text, .fr)])
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

    @Test("A best hypothesis under 0.6 returns the previous language", .tags(.requiresSystem))
    func unconfidentTextInherits() {
        // Measured on macOS 27.2: nl 0.545, en 0.402, fr 0.053 for this 22-unit mixed-language text.
        let detector = SystemLanguageDetector()
        #expect(detector.detect("bonjour hello hallo hi", previous: .fr) == .fr)
        #expect(detector.detect("bonjour hello hallo hi", previous: nil) == nil)
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

    @Test("Lemmas come from NaturalLanguage for English, never Dutch", .tags(.requiresSystem))
    func lemmas() async {
        let oracle = SystemWordOracle()
        let en = await oracle.facts(for: ["went", "walked"], language: .en)
        #expect(en.lemmas["went"] == "go")
        #expect(en.lemmas["walked"] == "walk")
        let nl = await oracle.facts(for: ["gebeurt", "gebeurd"], language: .nl)
        #expect(nl.lemmas.isEmpty)
    }

    @Test("Lemmas come from NaturalLanguage for French", .tags(.requiresSystem), .requiresFrenchTagger)
    func frenchLemmas() async {
        let fr = await SystemWordOracle().facts(for: ["sont"], language: .fr)
        #expect(fr.lemmas["sont"] == "être")
    }

    @Test("Function words are the listed ones plus pronouns, conjunctions and particles only", .tags(.requiresSystem))
    func functionWords() async {
        let oracle = SystemWordOracle()
        let en = await oracle.facts(for: ["the", "and", "all", "some", "afterwards", "tegen"], language: .en)
        #expect(en.functionWords.isSuperset(of: ["the", "and"]))
        #expect(en.functionWords.isDisjoint(with: ["all", "some", "afterwards", "tegen"]))
        let tagged = await oracle.facts(for: ["whoever", "up", "despite", "among"], language: .en)
        #expect(tagged.functionWords == ["whoever", "up"])
        let nl = await oracle.facts(for: ["de", "wel", "niet"], language: .nl)
        #expect(nl.functionWords == ["de"])
    }

    @Test("French function words include what the tagger calls a pronoun", .tags(.requiresSystem), .requiresFrenchTagger)
    func frenchFunctionWords() async {
        let fr = await SystemWordOracle().facts(for: ["quelqu'un", "malgré"], language: .fr)
        #expect(fr.functionWords == ["quelqu'un"])
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
