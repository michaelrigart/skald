import Foundation
import NaturalLanguage
import SkaldCore
import Testing
@testable import SkaldPlatform27

private final class Recorder: @unchecked Sendable { // reason: the lists are only touched under the lock
    private let lock = NSLock()
    private var asked: [NLLanguage] = []
    private var requested: [String] = []

    var installedChecks: [NLLanguage] { lock.withLock { asked } }
    var requests: [String] { lock.withLock { requested } }

    func checked(_ language: NLLanguage) { lock.withLock { asked.append(language) } }
    func requested(_ language: NLLanguage, _ scheme: NLTagScheme) {
        lock.withLock { requested.append("\(language.rawValue) \(scheme.rawValue)") }
    }
}

@Suite struct TaggerAssetsTests {
    @Test("A missing tagger is asked for once per launch, in both schemes")
    func missingTaggerIsAskedForOnce() async {
        let recorder = Recorder()
        let assets = TaggerAssets(isInstalled: { _ in false }, request: { recorder.requested($0, $1) })
        await assets.ensure(.fr)?.value
        #expect(recorder.requests == ["fr \(NLTagScheme.lemma.rawValue)", "fr \(NLTagScheme.lexicalClass.rawValue)"])
        #expect(assets.ensure(.fr) == nil)
        #expect(recorder.requests.count == 2)
    }

    @Test("An installed tagger is not asked for")
    func installedTaggerIsNotAskedFor() {
        let recorder = Recorder()
        let assets = TaggerAssets(isInstalled: { recorder.checked($0); return true }, request: { recorder.requested($0, $1) })
        #expect(assets.ensure(.en) == nil)
        #expect(assets.ensure(.en) == nil)
        #expect(recorder.requests.isEmpty)
        #expect(recorder.installedChecks.count == 1)
    }

    @Test("A language listed for only one scheme counts as missing")
    func oneSchemeIsNotEnough() {
        #expect(!TaggerAssets.covers([.lexicalClass]))
        #expect(!TaggerAssets.covers([.lemma]))
        #expect(TaggerAssets.covers([.lemma, .lexicalClass, .tokenType]))
    }

    @Test("English has a tagger and Dutch does not", .tags(.requiresSystem))
    func englishIsInstalledAndDutchIsNot() {
        #expect(TaggerAssets.isInstalled(.english))
        #expect(!TaggerAssets.isInstalled(.dutch))
    }

    @Test("Dutch has no tagger to ask for")
    func dutchHasNoTagger() {
        let recorder = Recorder()
        let assets = TaggerAssets(isInstalled: { recorder.checked($0); return false }, request: { recorder.requested($0, $1) })
        #expect(assets.ensure(.nl) == nil)
        #expect(recorder.installedChecks.isEmpty)
        #expect(recorder.requests.isEmpty)
    }

    @Test("A word lookup asks for a missing tagger without waiting for it", .tags(.requiresSystem), .timeLimit(.minutes(1)))
    func lookupDoesNotWaitForTheRequest() async {
        let recorder = Recorder()
        let (held, release) = AsyncStream.makeStream(of: Void.self)
        let assets = TaggerAssets(
            isInstalled: { recorder.checked($0); return false },
            request: { language, scheme in
                recorder.requested(language, scheme)
                for await _ in held {}
            })
        _ = await withTaskCancellationHandler {
            await SystemWordOracle(queue: .shared, assets: assets).facts(for: ["bonjour"], language: .fr)
        } onCancel: {
            release.finish()
        }
        #expect(recorder.installedChecks == [.french])
        release.finish()
    }
}
