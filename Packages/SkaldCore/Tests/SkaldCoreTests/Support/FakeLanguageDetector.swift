@testable import SkaldCore

/// Like the system detector: under 20 UTF-16 units it keeps `previous`; otherwise a marker phrase decides,
/// and anything else is `fallback`.
struct FakeLanguageDetector: LanguageDetecting {
    var markers: [(String, Language)] = [("Ik heb", .nl), ("J'ai", .fr)]
    var fallback: Language? = .en

    func detect(_ text: String, previous: Language?) -> Language? {
        guard text.utf16.count >= 20 else { return previous }
        return markers.first { text.contains($0.0) }?.1 ?? fallback
    }
}
