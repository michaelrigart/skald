import Testing
@testable import SkaldPlatform27

extension Tag {
    @Tag static var requiresSystem: Self
}

extension Trait where Self == ConditionTrait {
    static var requiresFrenchTagger: Self {
        .enabled(if: TaggerAssets.isInstalled(.french),
                 "no French tagger on this Mac")
    }
}
