import Foundation

public enum PanelResult: Equatable, Sendable {
    case revised(text: String, edits: [Edit], engine: EngineKind)
    case unavailable(EngineKind, UnavailableReason, alternatives: [EngineKind])
    case failed(EngineFailure)
    /// No paragraph's language could be detected or inherited: the user picks one with `choose`, then runs again.
    case needsLanguage
}

/// One opening of the panel: the captured text, Fix and the rewrites on the routed engine, and Replace.
/// Fix checks each paragraph in its own language with the guard, as checking while typing does; the
/// rewrites skip the guard. A newer run cancels the older one, whose result is then discarded.
public actor PanelSession {
    private static let actions: Set<EngineAction> = [.fix, .clearer, .shorter, .moreFormal, .friendlier]

    private let capture: SelectionCapture?
    private let text: String
    private let detector: any LanguageDetecting
    private let editGuard: EditGuard
    private let oracle: any WordOracle
    private let confirmer: (any EditConfirming)?
    private let engines: [EngineKind: any Engine]
    private let router: LiveRouter
    private let access: (any TextAccess)?
    private let fieldLanguage: Language?

    private var chosenLanguage: Language?
    private var running: Task<PanelResult, Never>?
    private var generation = 0

    public init(
        capture: SelectionCapture?,
        text: String,
        detector: any LanguageDetecting,
        editGuard: EditGuard,
        oracle: any WordOracle,
        confirmer: (any EditConfirming)?,
        engines: [EngineKind: any Engine],
        router: LiveRouter,
        access: (any TextAccess)?,
        fieldLanguage: Language? = nil
    ) {
        self.capture = capture
        self.text = text
        self.detector = detector
        self.editGuard = editGuard
        self.oracle = oracle
        self.confirmer = confirmer
        self.engines = engines
        self.router = router
        self.access = access
        self.fieldLanguage = fieldLanguage
    }

    /// True until the user picks a language, when some paragraph's language can't be detected or inherited.
    public func needsLanguage() -> Bool {
        languages(of: PanelText.paragraphs(text).map(\.text)) == nil
    }

    /// The language the user picked for the paragraphs Skald can't detect.
    public func choose(_ language: Language) {
        chosenLanguage = language
    }

    public func run(_ a: EngineAction, on e: EngineKind?) async -> PanelResult {
        running?.cancel()
        generation += 1
        let mine = generation
        let task = Task { await self.perform(a, on: e) }
        running = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard mine == generation, !Task.isCancelled else { return .failed(.cancelled) }
        running = nil
        return result
    }

    /// Writes `revised` over the captured selection, provided its paragraphs still read as captured.
    public func replace(with revised: String) async -> ReplaceOutcome {
        guard let capture, let access else { return .unsupported }
        return await access.replace(capture.selection, expected: capture.context, with: revised, in: capture.field)
    }

    // MARK: Running

    private func perform(_ action: EngineAction, on requested: EngineKind?) async -> PanelResult {
        guard Self.actions.contains(action) else { return .failed(.failed) }
        let parts = PanelText.paragraphs(text)
        guard let languages = languages(of: parts.map(\.text)) else { return .needsLanguage }
        let kind: EngineKind
        switch await router.current.panel(requested: requested) {
        case .use(let engine): kind = engine
        case let .unavailable(engine, reason, alternatives): return .unavailable(engine, reason, alternatives: alternatives)
        }
        guard let engine = engines[kind] else { return .failed(.failed) }
        do {
            let revised = action == .fix
                ? try await fix(parts, languages, with: engine)
                : try await rewrite(parts, languages, action, with: engine)
            guard !Task.isCancelled else { return .failed(.cancelled) }
            return .revised(text: revised, edits: TextDiff.edits(from: text, to: revised), engine: kind)
        } catch .unavailable(let reason) {
            return .unavailable(kind, reason, alternatives: await router.current.alternatives(to: kind))
        } catch {
            return .failed(error)
        }
    }

    private func fix(
        _ parts: [(text: String, separator: String)], _ languages: [Language?], with engine: any Engine
    ) async throws(EngineFailure) -> String {
        var parts = parts
        for (index, language) in languages.enumerated() {
            guard let language else { continue }
            let paragraph = parts[index].text
            let whole = Paragraph(range: TextRange(location: 0, length: paragraph.utf16.count), text: paragraph)
            var fixed = ""
            for chunk in Paragraphs.chunks(whole) {
                fixed += try await fix(chunk.text, language: language, with: engine)
            }
            parts[index].text = fixed
        }
        return PanelText.reassemble(parts)
    }

    /// The chunk with the edits the guard keeps applied; the chunk as it was when the answer is discarded whole.
    private func fix(_ chunk: String, language: Language, with engine: any Engine) async throws(EngineFailure) -> String {
        guard !Task.isCancelled else { throw .cancelled }
        let output = try await engine.run(EngineRequest(action: .fix, language: language, text: chunk))
        guard !Task.isCancelled else { throw .cancelled }
        let revised = OutputCleaner.clean(output, input: chunk)
        let whole = editGuard.judgeWhole(
            original: chunk, revised: revised, language: language, revisedLanguage: detector.detect(revised, previous: nil)
        )
        guard whole == .accepted else { return chunk }
        let router = self.router
        let gated = confirmer.map { inner in
            GatedConfirmer(inner: inner) { language in
                guard !Task.isCancelled else { return false }
                return await router.modelAllowed(language)
            }
        }
        let edits = TextDiff.edits(from: chunk, to: revised)
        let kept = await editGuard.resolve(edits, in: chunk, language: language, source: .model, oracle: oracle, confirmer: gated)
            .filter { !editGuard.touchesNeverTouch($0, in: chunk) }
        return Self.applying(kept, to: chunk)
    }

    /// One request for a selection in one language, else one per paragraph in its own language.
    private func rewrite(
        _ parts: [(text: String, separator: String)], _ languages: [Language?], _ action: EngineAction, with engine: any Engine
    ) async throws(EngineFailure) -> String {
        var parts = parts
        let written = languages.enumerated().compactMap { index, language in language.map { (index, $0) } }
        guard let first = written.first else { return text }
        if written.allSatisfy({ $0.1 == first.1 }) {
            let (lead, body, trail) = Self.trimmed(text)
            return lead + (try await rewrite(body, action, language: first.1, with: engine)) + trail
        }
        for (index, language) in written {
            let (lead, body, trail) = Self.trimmed(parts[index].text)
            parts[index].text = lead + (try await rewrite(body, action, language: language, with: engine)) + trail
        }
        return PanelText.reassemble(parts)
    }

    private func rewrite(_ body: String, _ action: EngineAction, language: Language, with engine: any Engine) async throws(EngineFailure) -> String {
        guard !Task.isCancelled else { throw .cancelled }
        let output = try await engine.run(EngineRequest(action: action, language: language, text: body))
        guard !Task.isCancelled else { throw .cancelled }
        let revised = OutputCleaner.clean(output, input: body)
        guard !revised.isEmpty else { throw .failed }
        return revised
    }

    // MARK: Languages

    /// Each paragraph's language, or nil when one can't be detected or inherited. Short paragraphs inherit the
    /// last confident language, starting from the captured lines, then the field's last confident language,
    /// then the user's pick. Skald never assumes one.
    /// Blank paragraphs, which are never sent, have none.
    private func languages(of paragraphs: [String]) -> [Language?]? {
        var previous = detector.detect(capture?.context.text ?? text, previous: nil) ?? fieldLanguage ?? chosenLanguage
        var languages: [Language?] = []
        for paragraph in paragraphs {
            guard !Self.isBlank(paragraph) else {
                languages.append(nil)
                continue
            }
            previous = detector.detect(paragraph, previous: previous)
            guard let previous else { return nil }
            languages.append(previous)
        }
        return languages
    }

    // MARK: Text

    private static func applying(_ edits: [Edit], to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.spliceRange.location > $1.spliceRange.location }) {
            result.replaceCharacters(in: NSRange(location: edit.spliceRange.location, length: edit.spliceRange.length), with: edit.spliceText)
        }
        return result as String
    }

    private static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy(\.properties.isWhitespace)
    }

    /// The text without its leading and trailing whitespace, and that whitespace, so a rewrite keeps it.
    private static func trimmed(_ text: String) -> (lead: String, body: String, trail: String) {
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
              let last = scalars.lastIndex(where: { !$0.properties.isWhitespace })
        else { return (text, "", "") }
        func string(_ slice: ArraySlice<Unicode.Scalar>) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: slice)
            return String(view)
        }
        return (string(scalars[..<first]), string(scalars[first...last]), string(scalars[(last + 1)...]))
    }
}
