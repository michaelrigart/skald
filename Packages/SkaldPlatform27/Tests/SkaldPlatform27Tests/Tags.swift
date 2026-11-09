import NaturalLanguage
import Testing

extension Tag {
    @Tag static var requiresSystem: Self
}

extension Trait where Self == ConditionTrait {
    static var requiresFrenchTagger: Self {
        .enabled(if: NLTagger.availableTagSchemes(for: .word, language: .french).contains(.lexicalClass),
                 "no French tagger on this Mac")
    }
}
