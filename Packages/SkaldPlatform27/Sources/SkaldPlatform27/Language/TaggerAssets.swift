import Foundation
import NaturalLanguage
import SkaldCore

extension Language {
    var taggerLanguage: NLLanguage? {
        switch self {
        case .en: .english
        case .fr: .french
        case .nl: nil
        }
    }
}

final class TaggerAssets: @unchecked Sendable { // reason: the handled set is only touched under the lock
    static let shared = TaggerAssets(
        isInstalled: isInstalled,
        request: { language, scheme in
            do {
                let result = try await NLTagger.requestAssets(for: language, tagScheme: scheme)
                PlatformLog.spelling.info("Tagger assets for \(language.rawValue, privacy: .public) \(scheme.rawValue, privacy: .public): \(String(describing: result), privacy: .public)")
            } catch {
                PlatformLog.spelling.error("Tagger assets for \(language.rawValue, privacy: .public) \(scheme.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        })

    private let isInstalled: @Sendable (NLLanguage) -> Bool
    private let request: @Sendable (NLLanguage, NLTagScheme) async -> Void
    private let lock = NSLock()
    private var handled: Set<NLLanguage> = []

    init(isInstalled: @escaping @Sendable (NLLanguage) -> Bool, request: @escaping @Sendable (NLLanguage, NLTagScheme) async -> Void) {
        self.isInstalled = isInstalled
        self.request = request
    }

    private static var schemes: [NLTagScheme] { [.lemma, .lexicalClass] }

    static func isInstalled(_ language: NLLanguage) -> Bool {
        covers(NLTagger.availableTagSchemes(for: .word, language: language))
    }

    static func covers(_ listed: [NLTagScheme]) -> Bool {
        schemes.allSatisfy(listed.contains)
    }

    @discardableResult
    func ensure(_ language: Language) -> Task<Void, Never>? {
        guard let tagged = language.taggerLanguage else { return nil }
        guard lock.withLock({ handled.insert(tagged).inserted }) else { return nil }
        guard !isInstalled(tagged) else { return nil }
        let request = request
        return Task.detached(priority: .utility) {
            for scheme in Self.schemes {
                await request(tagged, scheme)
            }
        }
    }
}
