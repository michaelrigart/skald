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
    public let kind: IssueKind
    public var description: String { name }

    public init(_ name: String, _ language: Language, _ paragraph: String, _ revised: String, _ expected: GuardVerdict,
                kind: IssueKind, source: IssueSource = .model, neverTouch: Set<String> = []) {
        self.name = name
        self.language = language
        self.paragraph = paragraph
        self.revised = revised
        self.source = source
        self.neverTouch = neverTouch
        self.expected = expected
        self.kind = kind
    }

    public init(_ id: String, _ old: String, _ new: String, _ expected: GuardVerdict,
                kind: IssueKind, source: IssueSource = .model, neverTouch: Set<String> = []) {
        let c = spike[id]!
        self.init("\(source == .spelling ? "spelling " : "")\(old) → \(new)", c.lang, c.text, swap(c.text, old, new), expected,
                  kind: kind, source: source, neverTouch: neverTouch)
    }
}

public let outcomeTable: [Row] = [
    Row("en1", "went", "gone", .keep, kind: .grammar),
    Row("nl6", "Hun", "Zij", .keep, kind: .grammar),
    Row("nl3", "als", "dan", .keep, kind: .grammar),
    Row("fr3", "est", "sont", .keep, kind: .grammar),
    Row("nl1", "word", "wordt", .keep, kind: .verbForm),
    Row("fr8", "regarderais", "regarderai", .keep, kind: .grammar),
    Row("nl2", "gedownloaded", "gedownload", .keep, kind: .spelling),
    Row("en3", "friday", "Friday", .keep, kind: .capital),
    Row("nl5", "voorvallen", "voorkomen", .drop(.replacement), kind: .grammar),
    Row("fr3", "passent", "se déroulent", .drop(.replacement), kind: .grammar),
    Row("frc2", "proprement", "correctement", .drop(.replacement), kind: .grammar),
    Row("nlc1", "gemerged", "gemerkt", .drop(.borrowedWord), kind: .grammar),
    Row("frc2", "mergé", "fusionné", .drop(.borrowedWord), kind: .spelling),
    Row("fr8", "tiens", "tiendrai", .drop(.tenseChange), kind: .grammar),
    Row("A final period", .en, spike["enc4"]!.text, spike["enc4"]!.text + ".", .drop(.addedFormality), kind: .punctuation),
    Row("nlc3", "Sidekiq-jobs", "", .drop(.nameNumberURLOrCode), kind: .spelling, source: .spelling),
    Row("enc1", "Talos", "Tacos", .drop(.nameNumberURLOrCode), kind: .spelling, source: .spelling),
    Row("en3", "Pieter", "Peter", .drop(.nameNumberURLOrCode), kind: .spelling, source: .spelling),
    Row("en2", "run", "runs", .drop(.neverTouch), kind: .grammar, neverTouch: ["run"]),
    Row("en2", "run", "runs", .drop(.neverTouch), kind: .grammar, neverTouch: ["Runs"]),
    Row("nlc4", "14e", "15e", .drop(.nameNumberURLOrCode), kind: .grammar),
    Row("A URL", .en, "Docs are at https://example.com/runbok today.", "Docs are at https://example.com/runbook today.",
        .drop(.nameNumberURLOrCode), kind: .spelling),
    Row("A www address", .en, "Docs are at www.example.com/runbok today.", "Docs are at www.example.com/runbook today.",
        .drop(.nameNumberURLOrCode), kind: .spelling),
    Row("Backticked code", .en, "Run `deploy_app` first.", "Run `deploy_apps` first.", .drop(.nameNumberURLOrCode), kind: .grammar),
    Row("A snake_case token", .en, "Run deploy_app first.", "Run deploy_apps first.", .drop(.nameNumberURLOrCode), kind: .grammar),
    Row("A camelCase token", .en, "Call getUserName first.", "Call getUsername first.", .drop(.nameNumberURLOrCode), kind: .capital),
    Row("A :: path", .en, "Call foo::runbok first.", "Call foo::runbook first.", .drop(.nameNumberURLOrCode), kind: .spelling),
    Row("A spelling flag without a guess", .nl, spike["nl4"]!.text,
        spike["nl4"]!.text.replacingOccurrences(of: "onmiddelijk ", with: ""), .drop(.noSuggestion), kind: .spelling, source: .spelling),
    Row("enc4", "ping", "Ping", .drop(.addedFormality), kind: .capital),
    Row("A capital in a paragraph that capitalises", .en, "Thanks for the update. we will ship it on monday.",
        "Thanks for the update. We will ship it on monday.", .keep, kind: .capital),
    Row("A name capitalised elsewhere", .en, "Thanks to Pieter for the review. I will ask pieter again.",
        "Thanks to Pieter for the review. I will ask Pieter again.", .keep, kind: .capital),
    Row("A capital on an unknown word", .en, "I will visit paris again.", "I will visit Paris again.", .undecided, kind: .capital),
    Row("A question mark ending an unpunctuated last sentence", .en, "Thanks for the fix. Can you deploy it",
        "Thanks for the fix. Can you deploy it?", .keep, kind: .punctuation),
    Row("A period ending an unpunctuated last sentence", .en, "We shipped it. The logs look fine",
        "We shipped it. The logs look fine.", .keep, kind: .punctuation),
    Row("A cognate in the plural", .fr, "Les nouvelles version sont prêtes", "Les nouvelles versions sont prêtes", .keep, kind: .grammar),
    Row("A cognate in the plural, Dutch", .nl, "Er zijn drie bug gevonden.", "Er zijn drie bugs gevonden.", .keep, kind: .grammar),
    Row("A cognate with its accent", .fr, "Cette operation est lente.", "Cette opération est lente.", .keep, kind: .accent),
    Row("A never-touch phrase with a dot", .en, "We run Node.js in production.", "We run Node.JS in production.",
        .drop(.neverTouch), kind: .capital, neverTouch: ["Node.js"]),
    Row("A hyphenated never-touch phrase", .en, "We keep it on-prem for now.", "We keep it on-premise for now.",
        .drop(.neverTouch), kind: .spelling, neverTouch: ["on-prem"]),
    Row("en2", "it's", "its", .keep, kind: .grammar, neverTouch: ["run"]),
    Row("A French weekday is lowercase", .fr, "On se voit lundi.", "On se voit Lundi.", .drop(.addedFormality), kind: .capital),
    Row("A Dutch weekday is lowercase", .nl, "Op maandag", "Op Maandag", .drop(.addedFormality), kind: .capital),
    Row("A Dutch adverb is not a function word", .nl, "Het werkt wel.", "Het werkt niet.", .drop(.replacement), kind: .grammar),
    Row("An English adverb is not a function word", .en, "I also checked the logs.", "I just checked the logs.", .drop(.replacement), kind: .grammar),
    Row("A French adverb is not a function word", .fr, "Je ne le fais plus.", "Je ne le fais jamais.", .drop(.borrowedWord), kind: .grammar),
    Row("A preposition swap is not a function-word fix", .nl, "Ik laat je iets weten tegen vrijdag.",
        "Ik laat je iets weten voor vrijdag.", .undecided, kind: .grammar),
    Row("A preposition replaced by a verb", .en, "I could of fixed it.", "I could have fixed it.", .undecided, kind: .grammar),
    Row("A preposition replaced by a content word", .nl, "De release schuift een week op.", "De release schuift een week uitgesteld.",
        .drop(.replacement), kind: .grammar),
    Row("A preposition replaced by a preposition", .en, "I am afraid from dogs.", "I am afraid of dogs.", .undecided, kind: .grammar),
    Row("A preposition that differs by an accent", .fr, "Il va a Paris", "Il va à Paris", .keep, kind: .accent),
    Row("A preposition with its final letter doubled", .en, "it looks of", "it looks off", .keep, kind: .grammar),
    Row("A near-homophone preposition", .en, "It is in the repo.", "It is on the repo.", .undecided, kind: .grammar),
    Row("A near-homophone Dutch preposition", .nl, "Het werkt voor vrijdag.", "Het werkt door vrijdag.", .undecided, kind: .grammar),
    Row("A French preposition swap", .fr, "Je travaille dans France.", "Je travaille en France.", .undecided, kind: .grammar),
    Row("A fixed expression: suppose to", .en, "I'm suppose to deploy.", "I'm supposed to deploy.", .keep, kind: .grammar),
    Row("A fixed expression: use to", .en, "I use to work there.", "I used to work there.", .keep, kind: .grammar),
    Row("An ambiguous contraction", .en, "I'd walk there.", "I'd walked there.", .undecided, kind: .grammar),
    Row("A final period after a sentence starting with I", .en, "lol. I'll ship it", "lol. I'll ship it.", .drop(.addedFormality), kind: .punctuation),
    Row("A tense change in English", .en, "I walk to the office.", "I walked to the office.", .drop(.tenseChange), kind: .grammar),
    Row("A participle after an auxiliary in English", .en, "I have walk home.", "I have walked home.", .keep, kind: .grammar),
    Row("A participle after a negated auxiliary", .en, "I haven't went there.", "I haven't gone there.", .keep, kind: .grammar),
    Row("A participle after a contracted auxiliary", .en, "She's went home.", "She's gone home.", .keep, kind: .grammar),
    Row("A first word after a bullet starts a sentence", .en, "- Fixd the bug", "- Fixed the bug", .keep, kind: .spelling, source: .spelling),
    Row("en1", "Hi Sarah", "Hi, Sarah", .keep, kind: .punctuation),
    Row("en3", "the the", "the", .keep, kind: .repeatedWord),
    Row("en6", "recieve", "receive", .keep, kind: .spelling),
    Row("en2", "it's", "its", .keep, kind: .grammar),
    Row("en7", "Lets", "Let's", .keep, kind: .grammar),
    Row("en2", "run", "runs", .keep, kind: .grammar),
    Row("nl5", "gebeurt", "gebeurd", .keep, kind: .verbForm),
    Row("nl3", "eigelijk", "eigenlijk", .keep, kind: .grammar),
    Row("fr6", "deja", "déjà", .keep, kind: .accent),
    Row("fr6", "lente", "lentes", .keep, kind: .grammar),
    Row("fr5", "envoyé", "envoyée", .keep, kind: .grammar),
    Row("fr7", "ces", "c'est", .keep, kind: .grammar),
    Row("A lone lowercase sentence stays lowercase", .en, "sure, I can take that one", "Sure, I can take that one",
        .drop(.addedFormality), kind: .capital),
    Row("A lone question keeps its lowercase start", .en, "can you take that one?", "Can you take that one?", .drop(.addedFormality), kind: .capital),
    Row("A lone sentence ending in a period gets its capital", .en, "thanks for the quick fix.", "Thanks for the quick fix.", .keep, kind: .capital),
    Row("A contraction fragment is not a misspelling", .en, "We didn't received the alerts.", "We did not receive the alerts.",
        .drop(.tenseChange), kind: .grammar),
    Row("Two separate letter changes are not a near-homophone", .nl, "We moeten de kelder nog opkuisen.",
        "We moeten de kelder nog opruimen.", .drop(.replacement), kind: .grammar),
    Row("A content word with an unknown lemma is a replacement", .fr, "Le budget reste à septante mille euros.",
        "Le budget reste à soixante mille euros.", .drop(.replacement), kind: .grammar),
    Row("A guess that splits a word into content words", .en, "Check the runbook first.", "Check the run book first.",
        .drop(.compoundSplit), kind: .spelling, source: .spelling),
    Row("A guess that splits off a function word", .en, "It took alot of time.", "It took a lot of time.", .keep, kind: .spelling, source: .spelling),
    Row("A restored apostrophe is not a split", .en, "I cant make it today.", "I can't make it today.", .undecided, kind: .grammar),
    Row("A restored apostrophe inside a word is not a split", .fr, "Je regarde ça aujourdhui.", "Je regarde ça aujourd'hui.", .keep, kind: .spelling,
        source: .spelling),
    Row("The model splitting a compound is not a guess", .en, "We fallback to the replica.", "We fall back to the replica.", .undecided, kind: .grammar),
    Row("A word without vowels is an abbreviation", .en, "fyi the vpn is down", "fyi the van is down",
        .drop(.nameNumberURLOrCode), kind: .spelling, source: .spelling),
    Row("A vowel-less typo whose letters the fix keeps", .en, "I checked th logs.", "I checked the logs.", .keep, kind: .spelling, source: .spelling),
    Row("A lowercase abbreviation keeps its case", .en, "fyi the vpn is down", "fyi the VPN is down", .drop(.nameNumberURLOrCode), kind: .capital),
    Row("A chat abbreviation the fix spells out", .en, "pls check the logs", "please check the logs", .drop(.nameNumberURLOrCode), kind: .grammar),
    Row("A chat abbreviation with a letter the fix lacks", .en, "thx for checking", "thanks for checking", .drop(.nameNumberURLOrCode), kind: .grammar),
    Row("A vowel-less typo two letters short", .en, "Send the fnl version.", "Send the final version.", .keep, kind: .spelling, source: .spelling),
    Row("A vowel-less typo one letter short", .en, "Copy it frm the wiki.", "Copy it from the wiki.", .keep, kind: .spelling, source: .spelling),
    Row("A two-letter chat abbreviation: tt", .fr, "je regarde tt ça demain", "je regarde tout ça demain", .drop(.nameNumberURLOrCode), kind: .grammar),
    Row("A two-letter chat abbreviation: ds", .fr, "c'est ds le wiki", "c'est dans le wiki", .drop(.nameNumberURLOrCode), kind: .grammar),
    Row("A two-letter chat abbreviation: dc", .fr, "ok dc on attend lundi", "ok donc on attend lundi", .drop(.nameNumberURLOrCode), kind: .spelling),
    Row("A two-letter chat abbreviation: pr", .fr, "merci pr le retour", "merci pour le retour", .drop(.nameNumberURLOrCode), kind: .grammar),
    Row("colour → color", .en, "I like the colour of the new logo.", "I like the color of the new logo.", .drop(.spellingVariant), kind: .grammar),
    Row("behaviour → behavior", .en, "His behaviour was odd during the call.", "His behavior was odd during the call.",
        .drop(.spellingVariant), kind: .grammar),
    Row("color → colour", .en, "I like the color of the new logo.", "I like the colour of the new logo.", .drop(.spellingVariant), kind: .grammar),
    Row("centre → center, a spelling both dictionaries accept", .en, "The centre of town is closed today.",
        "The center of town is closed today.", .drop(.spellingVariant), kind: .grammar),
    Row("loose → lose, two words both dictionaries accept", .en, "Don't loose the key.", "Don't lose the key.", .keep, kind: .grammar),
    Row("behavour → behaviour", .en, "His behavour was odd during the call.", "His behaviour was odd during the call.", .keep, kind: .spelling),
    Row("spelling behavour → behaviour", .en, "His behavour was odd during the call.", "His behaviour was odd during the call.", .keep, kind: .spelling,
        source: .spelling),
    Row("A French word English also has, fixed to another French word", .fr,
        "Tout les serveurs sont à jour", "Tous les serveurs sont à jour", .keep, kind: .grammar),
    Row("A French borrowing fixed to a French word", .fr,
        "J'ai mergé le correctif", "J'ai fusionné le correctif", .drop(.borrowedWord), kind: .spelling),
    Row("A Dutch borrowing fixed to a Dutch word", .nl,
        "Ik heb de fix gemerged", "Ik heb de fix gemerkt", .drop(.borrowedWord), kind: .grammar),
    Row("A Dutch word English also has, fixed to another Dutch word", .nl,
        "Het was een warm dag", "Het was een warme dag", .keep, kind: .grammar),
    Row("A French loanword the dictionary accepts, translated", .fr,
        "Je pars ce weekend avec eux.", "Je pars cette fin de semaine avec eux.", .drop(.borrowedWord), kind: .grammar),
    Row("A Dutch loanword the dictionary accepts, translated", .nl,
        "De deadline is vrijdag.", "De uiterste datum is vrijdag.", .drop(.borrowedWord), kind: .grammar),
]

/// A paragraph's proposals judged together by `resolve` without a confirmer; `kept` lists "original → replacement".
public struct ResolveRow: Sendable, CustomStringConvertible {
    let name: String
    public let language: Language
    public let paragraph: String
    public let source: IssueSource
    public let kept: [String]
    private let proposals: [String]
    public var description: String { name }

    public init(_ name: String, _ language: Language, _ paragraph: String, _ proposals: [String], source: IssueSource = .model,
                kept: [String]) {
        self.name = name
        self.language = language
        self.paragraph = paragraph
        self.proposals = proposals
        self.source = source
        self.kept = kept
    }

    public var edits: [Edit] {
        proposals.flatMap { TextDiff.edits(from: paragraph, to: $0) }
    }
}

public let resolveTable: [ResolveRow] = [
    ResolveRow("A function word one token from a replaced verb", .fr, "Les documents sont sur mon bureau, sers-toi.",
               ["Les documents sont sur mon bureau, prends-les."], kept: []),
    ResolveRow("A fix two tokens from a replaced verb", .fr, "Les tests passent et les serveur sont à jour.",
               ["Les tests se déroulent et les serveurs sont à jour."], kept: ["serveur → serveurs"]),
    ResolveRow("A misspelling fix one token from a replaced verb", .fr, "Les tests passent sans probleme.",
               ["Les tests se déroulent sans problème."], kept: ["probleme → problème"]),
    ResolveRow("A capital one token from a replaced verb", .fr, "Les tests passent. il faut encore voir.",
               ["Les tests se déroulent. Il faut encore voir."], kept: ["il → Il"]),
    ResolveRow("Spelling flags never take their neighbours", .fr, "J'ai mergé deja le correctif.",
               ["J'ai Serge deja le correctif.", "J'ai mergé déjà le correctif."], source: .spelling, kept: ["deja → déjà"]),
]

public let measuredGuesses: [Row] =
    ["reviews", "review", "reviert", "Previewt"].map { Row("nlc4", "reviewt", $0, .drop(.borrowedWord), kind: .spelling, source: .spelling) }
    + ["Serge", "marge", "Hergé", "merle", "margé"].map { Row("frc2", "mergé", $0, .drop(.borrowedWord), kind: .spelling, source: .spelling) }

