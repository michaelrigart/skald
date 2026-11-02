import Foundation
import SkaldCore

public let spike: [String: EvalCase] = {
    let cases: [EvalCase] = try! EvalScorer.loadJSONL(SpikeFixtures.url("testset"))
    return Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })
}()

public func swap(_ text: String, _ old: String, _ new: String) -> String {
    let pattern = "(?<!\\w)" + NSRegularExpression.escapedPattern(for: old) + "(?!\\w)"
    let regex = try! NSRegularExpression(pattern: pattern)
    let ns = text as NSString
    let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))!
    return ns.replacingCharacters(in: match.range, with: new)
}

public struct Row: Sendable, CustomStringConvertible {
    let name: String
    public let language: Language
    public let paragraph: String
    public let revised: String
    public let source: IssueSource
    public let neverTouch: Set<String>
    public let expected: GuardVerdict
    public var description: String { name }

    public init(_ name: String, _ language: Language, _ paragraph: String, _ revised: String, _ expected: GuardVerdict,
                source: IssueSource = .model, neverTouch: Set<String> = []) {
        self.name = name
        self.language = language
        self.paragraph = paragraph
        self.revised = revised
        self.source = source
        self.neverTouch = neverTouch
        self.expected = expected
    }

    public init(_ id: String, _ old: String, _ new: String, _ expected: GuardVerdict,
                source: IssueSource = .model, neverTouch: Set<String> = []) {
        let c = spike[id]!
        self.init("\(source == .spelling ? "spelling " : "")\(old) → \(new)", c.lang, c.text, swap(c.text, old, new), expected,
                  source: source, neverTouch: neverTouch)
    }
}

public let outcomeTable: [Row] = [
    Row("en1", "went", "gone", .keep),
    Row("nl6", "Hun", "Zij", .keep),
    Row("nl3", "als", "dan", .keep),
    Row("fr3", "est", "sont", .keep),
    Row("nl1", "word", "wordt", .keep),
    Row("fr8", "regarderais", "regarderai", .keep),
    Row("nl2", "gedownloaded", "gedownload", .keep),
    Row("en3", "friday", "Friday", .keep),
    Row("nl5", "voorvallen", "voorkomen", .undecided),
    Row("fr3", "passent", "se déroulent", .drop(.replacement)),
    Row("frc2", "proprement", "correctement", .drop(.replacement)),
    Row("nlc1", "gemerged", "gemerkt", .drop(.borrowedWord)),
    Row("frc2", "mergé", "fusionné", .drop(.borrowedWord)),
    Row("fr8", "tiens", "tiendrai", .drop(.tenseChange)),
    Row("A final period", .en, spike["enc4"]!.text, spike["enc4"]!.text + ".", .drop(.addedFormality)),
    Row("nlc3", "Sidekiq-jobs", "", .drop(.nameNumberURLOrCode), source: .spelling),
    Row("enc1", "Talos", "Tacos", .drop(.nameNumberURLOrCode), source: .spelling),
    Row("en3", "Pieter", "Peter", .drop(.nameNumberURLOrCode), source: .spelling),
    Row("en2", "run", "runs", .drop(.neverTouch), neverTouch: ["run"]),
    Row("en2", "run", "runs", .drop(.neverTouch), neverTouch: ["Runs"]),
    Row("nlc4", "14e", "15e", .drop(.nameNumberURLOrCode)),
    Row("A URL", .en, "Docs are at https://example.com/runbok today.", "Docs are at https://example.com/runbook today.",
        .drop(.nameNumberURLOrCode)),
    Row("A www address", .en, "Docs are at www.example.com/runbok today.", "Docs are at www.example.com/runbook today.",
        .drop(.nameNumberURLOrCode)),
    Row("Backticked code", .en, "Run `deploy_app` first.", "Run `deploy_apps` first.", .drop(.nameNumberURLOrCode)),
    Row("A snake_case token", .en, "Run deploy_app first.", "Run deploy_apps first.", .drop(.nameNumberURLOrCode)),
    Row("A camelCase token", .en, "Call getUserName first.", "Call getUsername first.", .drop(.nameNumberURLOrCode)),
    Row("A :: path", .en, "Call foo::runbok first.", "Call foo::runbook first.", .drop(.nameNumberURLOrCode)),
    Row("A spelling flag without a guess", .nl, spike["nl4"]!.text,
        spike["nl4"]!.text.replacingOccurrences(of: "onmiddelijk ", with: ""), .drop(.noSuggestion), source: .spelling),
    Row("enc4", "ping", "Ping", .drop(.addedFormality)),
    Row("A capital in a paragraph that capitalises", .en, "Thanks for the update. we will ship it on monday.",
        "Thanks for the update. We will ship it on monday.", .keep),
    Row("A name capitalised elsewhere", .en, "Thanks to Pieter for the review. I will ask pieter again.",
        "Thanks to Pieter for the review. I will ask Pieter again.", .keep),
    Row("A capital on an unknown word", .en, "I will visit paris again.", "I will visit Paris again.", .undecided),
    Row("A question mark ending an unpunctuated last sentence", .en, "Thanks for the fix. Can you deploy it",
        "Thanks for the fix. Can you deploy it?", .keep),
    Row("A period ending an unpunctuated last sentence", .en, "We shipped it. The logs look fine",
        "We shipped it. The logs look fine.", .keep),
    Row("A cognate in the plural", .fr, "Les nouvelles version sont prêtes", "Les nouvelles versions sont prêtes", .keep),
    Row("A cognate in the plural, Dutch", .nl, "Er zijn drie bug gevonden.", "Er zijn drie bugs gevonden.", .keep),
    Row("A cognate with its accent", .fr, "Cette operation est lente.", "Cette opération est lente.", .keep),
    Row("A never-touch phrase with a dot", .en, "We run Node.js in production.", "We run Node.JS in production.",
        .drop(.neverTouch), neverTouch: ["Node.js"]),
    Row("A hyphenated never-touch phrase", .en, "We keep it on-prem for now.", "We keep it on-premise for now.",
        .drop(.neverTouch), neverTouch: ["on-prem"]),
    Row("en2", "it's", "its", .keep, neverTouch: ["run"]),
    Row("A French weekday is lowercase", .fr, "On se voit lundi.", "On se voit Lundi.", .drop(.addedFormality)),
    Row("A Dutch weekday is lowercase", .nl, "Op maandag", "Op Maandag", .drop(.addedFormality)),
    Row("A Dutch adverb is not a function word", .nl, "Het werkt wel.", "Het werkt niet.", .undecided),
    Row("An English adverb is not a function word", .en, "I also checked the logs.", "I just checked the logs.", .drop(.replacement)),
    Row("A French adverb is not a function word", .fr, "Je ne le fais plus.", "Je ne le fais jamais.", .drop(.borrowedWord)),
    Row("A preposition swap is not a function-word fix", .nl, "Ik laat je iets weten tegen vrijdag.",
        "Ik laat je iets weten voor vrijdag.", .undecided),
    Row("A preposition replaced by a verb", .en, "I could of fixed it.", "I could have fixed it.", .undecided),
    Row("A preposition replaced by a preposition", .en, "I am afraid from dogs.", "I am afraid of dogs.", .undecided),
    Row("A preposition that differs by an accent", .fr, "Il va a Paris", "Il va à Paris", .keep),
    Row("A preposition with its final letter doubled", .en, "it looks of", "it looks off", .keep),
    Row("A near-homophone preposition", .en, "It is in the repo.", "It is on the repo.", .undecided),
    Row("A near-homophone Dutch preposition", .nl, "Het werkt voor vrijdag.", "Het werkt door vrijdag.", .undecided),
    Row("A French preposition swap", .fr, "Je travaille dans France.", "Je travaille en France.", .undecided),
    Row("A fixed expression: suppose to", .en, "I'm suppose to deploy.", "I'm supposed to deploy.", .keep),
    Row("A fixed expression: use to", .en, "I use to work there.", "I used to work there.", .keep),
    Row("An ambiguous contraction", .en, "I'd walk there.", "I'd walked there.", .undecided),
    Row("A final period after a sentence starting with I", .en, "lol. I'll ship it", "lol. I'll ship it.", .drop(.addedFormality)),
    Row("A tense change in English", .en, "I walk to the office.", "I walked to the office.", .drop(.tenseChange)),
    Row("A participle after an auxiliary in English", .en, "I have walk home.", "I have walked home.", .keep),
    Row("A participle after a negated auxiliary", .en, "I haven't went there.", "I haven't gone there.", .keep),
    Row("A participle after a contracted auxiliary", .en, "She's went home.", "She's gone home.", .keep),
    Row("A first word after a bullet starts a sentence", .en, "- Fixd the bug", "- Fixed the bug", .keep, source: .spelling),
    Row("en1", "Hi Sarah", "Hi, Sarah", .keep),
    Row("en3", "the the", "the", .keep),
    Row("en6", "recieve", "receive", .keep),
    Row("en2", "it's", "its", .keep),
    Row("en7", "Lets", "Let's", .keep),
    Row("en2", "run", "runs", .keep),
    Row("nl5", "gebeurt", "gebeurd", .keep),
    Row("nl3", "eigelijk", "eigenlijk", .keep),
    Row("fr6", "deja", "déjà", .keep),
    Row("fr6", "lente", "lentes", .keep),
    Row("fr5", "envoyé", "envoyée", .keep),
    Row("fr7", "ces", "c'est", .keep),
]

public let measuredGuesses: [Row] =
    ["reviews", "review", "reviert", "Previewt"].map { Row("nlc4", "reviewt", $0, .drop(.borrowedWord), source: .spelling) }
    + ["Serge", "marge", "Hergé", "merle", "margé"].map { Row("frc2", "mergé", $0, .drop(.borrowedWord), source: .spelling) }

