# Skald: design

**Date:** 2026-11-02
**Owner:** Michael Rigart
**Status:** In progress (branch `feat/skald-v1`; no merge request yet, because the repository
has no remote).
**Sign-off:** not yet given by Michael. On 2026-11-02 he asked for the work to continue without
him overnight. Codex approved the spec in round 4 (`xr-1793578392-bfc59cef`). The calls marked
as Claude's under Decisions are his to check.
**Name:** Skald, after the poets of the Norse courts.

## Why

Michael wants a Grammarly replacement that runs on his own Mac. He writes in English, Dutch and
sometimes French, in Belgian usage, across native Mac apps, Electron apps and the browser. The
checking should run on the Mac's own hardware, preferably the Neural Engine, and must not load
the Mac he does development work on. For heavier work he wants the option of a remote engine,
the way Muninn offers the Mac Studio and Claude.

Skald is the next app in his Mac suite, after Muninn, Linger, Hulder and Tafl. It does a few
things reliably, and its codebase stays high quality.

## Measured on macOS 27.2

A throwaway spike on 2026-11-01 and 2026-11-02 measured the engines on an Apple silicon laptop
running macOS 27.2, with a typical development workload running in the background.

**Method.**
- **Test set:** 36 paragraphs, 12 per language (English, Dutch, French). Each language has 8
  paragraphs with seeded errors and 4 clean ones, the clean ones holding traps: English tech
  words inside Dutch and French, Belgian usage ("tegen vrijdag", "proper", "septante",
  "we wachten best"), informal Slack style and French spacing before "!". The set is in the
  appendix.
- **Prompt:** the same instructions for every engine, with greedy sampling and one fresh session
  per paragraph; the paragraph itself is the prompt:

  > You are a proofreader. Fix only spelling, grammar and punctuation errors in the user's text.
  > Keep the original language, wording, tone, technical terms, names and informal style.
  > Belgian Dutch and Belgian French usage is correct and must stay. Do not rephrase or improve
  > style. Reply with the corrected text only, with no explanation. If there are no errors,
  > reply with the text exactly as given.

  The language hint appends: "The text is written in *Language*. Reply in *Language*. Leave any
  English words in it unchanged." The Qwen runs also append "/no_think" and strip the empty
  thinking block from the answer.
- **Scoring:** token-level diff of input against output, compared with the reference
  corrections. Precision and recall are per edit; "clean false alarms" counts clean paragraphs
  with any edit.
- **Power:** `powermetrics` (CPU, GPU and ANE samplers, 500 ms) during each run, against a
  15-second idle baseline. Without root, macOS 27 reports only GPU energy through IOReport;
  CPU, ANE and DRAM counters read zero.
- **Kept:** the test set, the prompt, the scorer and every engine's raw per-paragraph outputs
  move into the repository as test fixtures in the plan's first task. Two company names in the
  set were replaced with fictional ones after the spike, in the inputs and the outputs alike.

**Results.**

| Engine | Recall | Precision | Clean false alarms | Time per paragraph (p50 / p90) | Start-up | Power while checking |
|---|---|---|---|---|---|---|
| Apple on-device model, with a language hint | 0.97 (34/35) | 0.85 | 2/12 | 0.45 s / 0.55 s | none | ANE 3.0 W, CPU +2.7 W over idle, GPU ≈ 0 |
| Apple on-device model, no language hint | 0.94 | 0.80 | 2/12 | 0.43 s / 0.58 s | none | (not measured separately) |
| Qwen3 4B via Core AI, Neural Engine export | 0.46 | 0.84 | 2/12 | 1.06 s / 1.30 s | 11 min one-time compile (CPU ≈ 12.8 W, peaks near 40 W), 9.4 s cached | ANE 3.5 W, CPU +1.1 W, GPU ≈ 0 |
| Qwen3 4B via Core AI, GPU export | 0.51 | 0.90 | 2/12 | 0.55 s / 0.66 s | 14 s | GPU ≈ 12.5 W |

**Findings.**
1. **Apple's on-device model is the right engine for checking while typing.** It has the best
   quality in all three languages, runs on the Neural Engine (confirmed by `powermetrics`),
   leaves the GPU alone, needs no download or compile, and lives in the OS rather than in
   Skald's memory. It supports `en`, `nl-NL` and `fr-FR` among others. Results were identical
   across two runs.
2. **The model must be told the paragraph's language.** Naming the language per paragraph
   raised precision from 0.80 to 0.85 and fixed the one English miss. An instruction that
   mentions several languages at once made it translate English paragraphs into Dutch
   (precision 0.41): instructions stay short and name one language.
3. **The remaining false alarms are the model improving correct text.** Synonym swaps
   ("voorvallen" → "voorkomen", "passent" → "se déroulent", "proprement" → "correctement"),
   translated anglicisms ("gemerged" → "gemerkt", "mergé" → "fusionné") and a tense change
   ("tiens" → "tiendrai"). Skald therefore judges every edit itself (see "The edit guard")
   instead of trusting the model's output.
4. **Open models through Core AI work but don't earn their place yet.** Qwen3 4B was weak in
   Dutch and French on either chip (0 to 2 of 9 Dutch errors fixed), so the problem is the
   model, not the hardware. The Neural Engine export stays off the GPU, but its first load
   compiled for 11 minutes at high CPU power. The GPU export loads the GPU at about 12.5 W.
   Core AI models conform to the same Foundation Models `LanguageModel` interface as Apple's
   model, so one can be added later without redesign.
5. **Reading text from other apps.** With Accessibility granted, Notes' text view exposes its
   value, selection and on-screen bounds for a character range, and both its value and selected
   text are settable. Zen's text fields expose the same. Electron apps (Proton Mail, Signal,
   Slack, Obsidian), Mail and rich-text editors in the browser (Basecamp, GitLab) were not yet
   probed with a focused field: that is the plan's first task.
6. **Word lookups are uneven across the three languages.**
   - `NSSpellChecker` has `en` (American), `en_GB`, `nl` and `fr` dictionaries. On the spike's
     text the Dutch one flagged the correct "reviewt" and "Sidekiq-jobs" and missed "eigelijk";
     the French one flagged the anglicism "mergé". British and American spellings are each
     flagged by the other dictionary.
   - Natural Language gives lemmas and word classes for English and French, but neither for
     Dutch. Dutch function words therefore come from Skald's own word lists, and a Dutch
     same-lemma test falls back to the near-homophone rule.
   - Language detection constrained to the three languages is reliable on a sentence, but its
     hypotheses for a word or two ("ok") are noise. Only the three languages are considered,
     and short paragraphs inherit the field's last confident language.
   - The spell server is unreachable from inside an agent sandbox; these lookups run outside
     it.
7. **Text access per app, and the model inside the signed app** (the plan's feasibility probe,
   2026-11-05 and 2026-11-06, a signed build run from `/Applications` with Michael at the
   Mac). This answers finding 5's open question.

   | App and field | Read through | Range bounds | Clean write | ⌘Z | Class |
   |---|---|---|---|---|---|
   | Notes | ranges | yes | Accessibility, formatting kept | exact; earlier history survives | full |
   | TextEdit | ranges | yes | Accessibility, formatting kept | exact; earlier history survives | full |
   | Zen: a textarea, GitLab's comment box | ranges | yes, stable through scrolling | paste | exact; earlier history survives | full |
   | Zen: Basecamp's editor (Trix) | ranges | yes | paste | exact; earlier history survives | full |
   | Slack | ranges | no; field frame | paste | exact | badge |
   | Signal | ranges | no; field frame | paste | exact | badge |
   | Obsidian | ranges | no; field frame | paste | exact | badge |
   | Proton Mail | ranges; the caret reads 0 after a paste | no; field frame | none: a paste adds a line break | exact | badge, Copy only |
   | Mail (compose) | text markers | not measured; field frame | paste | exact | badge |

   - **Accessibility writes** are clean only in Notes and TextEdit. Elsewhere the app accepts
     the call and then ignores it (Signal, Obsidian), inserts the text one unit off
     without removing the old text (Zen's text areas, the open Firefox bug 1866621), or applies
     it some time later (Zen's plain input). A paste of the same replacement landed exactly
     within about 25 ms in Zen's text areas (including GitLab's comment box), Signal, Obsidian
     and Slack.
   - **Undo.** Slack merges edits made within about a second into one undo step: a paste that
     follows the user's own edit too closely is undone together with it, hence the paste
     write's quiet period. With it, the first ⌘Z after a paste restored the text exactly in
     every paste app. A second ⌘Z removed the user's own previous edit wherever it was
     measured (Notes, TextEdit, Zen's text areas, Basecamp), so the app's earlier history
     survives; a paste is an ordinary edit in the app's own undo stack.
   - **Electron apps** need `AXManualAccessibility`; Obsidian's focused element appears about
     1 s after it is set. They give the field's frame but no bounds for a character range, so
     they get the badge. Zen's fields give range bounds; its textarea's stayed correct through
     scrolling.
   - **Change notifications** (value, selection, focus) arrived within 2 s of a keystroke in
     every text field probed.
   - **Text markers.** Mail's compose area is a web area that is its own editable element; it
     answers text-marker reads (the text, and the caret as marker-range lengths), not
     character ranges. WebKit doesn't answer `AXStartTextMarkerForTextMarkerRange` or
     `AXIndexForTextMarker`; the public `AXTextMarkerRangeCopyStartMarker` and marker-range
     lengths do the job. Mail's focused element appears about 1 s after the app is
     activated. Proton Mail's composer reads through ranges while typing, but after a paste
     its caret reads 0 until the next keystroke, and its text-marker selection comes and
     goes.
   - **Editors that format as you type.** Basecamp's Trix turns `~text~` into
     strikethrough, so the probe's marker needed a form without tildes there. Zen's
     rich-text editors are ordinary text areas to Accessibility once focused; no browser
     extension is needed.
   - **Cost of asking for the tree.** The probe couldn't take a clean before-and-after pair:
     an Electron app has no focused element until accessibility is on. While the probe was
     reading them, Signal used 10–17 % of a core and Obsidian 7–14 %. Left on afterwards,
     with nothing reading them, Signal and Slack idled at 1–2 %. Firefox answers
     `AXEnhancedUserInterface` with an error and builds its tree for any client that asks,
     so Zen's cost is the cost of being read at all; its samples during the probe (40–94 %)
     were taken while Michael browsed. Ten minutes of `powermetrics` at acceptance measure
     the cost while typing.
   - **Apple's model inside the signed app,** on the seed set with the spike's prompt and
     scorer: recall 0.97 (34/35), precision 0.83, 3 of 12 clean paragraphs flagged, 0.47 s /
     0.57 s per paragraph (p50 / p90). The one difference from the spike's run is a new Dutch
     false alarm, "reviewt" → "beoordeelt", a translated anglicism the edit guard drops.

## Success

- Michael uses Skald instead of Grammarly in his daily writing in all three languages.
- It catches typical errors while he types and stays quiet on correct text, including Belgian
  usage and English technical words inside Dutch and French.
- A suggestion appears within about a second after he pauses typing.
- His Mac stays as usable as without Skald: checking while typing never touches the GPU and adds
  no noticeable CPU load or heat.
- Accepting a suggestion changes exactly the flagged words, keeps the caret where he expects
  it, and can be undone with ⌘Z where the app supports it.
- When a macOS update changes Apple's model, the evaluation set shows whether quality changed
  before he notices.

## Goals (v1)

1. **Check while typing.** After a pause, Skald checks the paragraph around the caret in the
   focused text field, underlines issues in place, and offers a correction on click.
2. **Proofread or rewrite on demand.** A global hotkey opens a panel for the selection, or the
   current paragraph when nothing is selected. It offers Fix (proofread), and rewrites: Clearer,
   Shorter, More formal, Friendlier. It shows the changes, and Replace puts the result back in
   the field.
3. **Three languages,** English, Dutch and French, detected per paragraph, in Belgian usage.
4. **Engines.** This Mac (Apple's on-device model) for everything; the Mac Studio and Claude as
   optional engines for the panel, as in Muninn.
5. **Control.** Pause, turn Skald off per app, and a list of words Skald never touches.
6. **Housekeeping.** Menu bar icon, no Dock icon, launch at login, everything remembered.

## Non-goals (v1)

Each of these can come later, if it fits the architecture below.

- **Open local models** through Core AI or MLX. The engine interface allows them; none ships in
  v1 (finding 4).
- **A browser extension,** unless the feasibility check shows Zen's rich-text editors can't be
  read or written through Accessibility (see Delivery).
- **The Mac Studio or Claude for checking while typing.**
- **Whole-document checks,** style scores, tone detection, plagiarism, statistics, goals.
- **Languages beyond English, Dutch and French.**
- **Distribution:** automatic updates, the Mac App Store (Skald can't be sandboxed), interface
  localisation (English only).
- **macOS 26 and earlier,** and Macs without Apple Intelligence.

## Anti-goals

Skald has failed, even if it works, if it:

- nags: flags correct text, Belgian usage, or English technical words in Dutch and French;
- rewrites, rephrases or translates when the user asked for a fix, or while checking as they
  type;
- changes any text the user didn't accept, or replaces text that changed since it was checked
  (with one accepted exception: a paste that lands in the instant after Skald's last check,
  see the text access contract);
- leaves the clipboard different from how it found it after a paste write, unless the user
  or another app copied something meanwhile, or the paste was never confirmed (then the
  clipboard holds the fix, and Skald says so);
- sends text off the Mac unless the user chose a remote engine for that action or made one the
  panel's default;
- writes user text to disk, logs it, or collects telemetry. Only the never-touch list is stored;
- reads secure text fields, or apps the user excluded;
- uses the GPU, or causes noticeable CPU load or heat, while checking as the user types;
- downloads or compiles a model on the Mac;
- steals focus, moves the caret, breaks the app's undo, or slows typing;
- blocks the main thread on an Accessibility call, or hangs when an app doesn't answer;
- shows a Dock icon, or opens windows nobody asked for.

## Constraints

- **Platform.** macOS 27 and later; deployment target 27.0, as in Hulder. Measured on 27.2.
  Apple Intelligence must be on for model checks.
- **Stack.**
  - Swift 6 with strict concurrency checking; Swift Testing.
  - SwiftUI for windows and the panel. AppKit for the status item and the overlay.
  - Foundation Models for Apple's model. Natural Language for language detection.
    `NSSpellChecker` for spelling.
  - Not sandboxed (Accessibility access to other apps rules it out). Hardened Runtime on.
- **Install location.** `/Applications`, launched with `open`, so the Accessibility grant goes
  to Skald and not to a terminal.
- **Identity.** Bundle identifier `com.michaelrigart.skald`.
- **Signing.** Michael's Apple Development certificate (his Personal Team), so the
  Accessibility grant survives rebuilds. A builder without it signs ad hoc and grants
  Accessibility again after every rebuild. (Ad hoc until 2026-11-05.)
- **Toolchain.** The same as Hulder:
  - Xcode through `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` per command.
  - XcodeGen, pinned in the repository's `mise.toml`; the generated project is not tracked.
  - Builds and tests run outside any agent sandbox.
- **Secrets.** The Claude API key lives in the macOS Keychain, never in a file or a log.
- **Repository and license.**
  - Lives at `~/Code/skald`, under the MIT license.
  - Becomes a public GitHub repository under `michaelrigart` when Michael says so.
  - Public docs stay free of details about Michael's machine.

## Architecture

Three parts, as in Hulder, so that a macOS change or a new engine touches one layer.

1. **SkaldCore,** a Swift package. Foundation only: no AppKit, SwiftUI, ApplicationServices,
   Foundation Models or `#available` checks. It holds:
   - **The text model:** a field snapshot (text, selection, the field's identity and a
     revision), paragraphs within it, and issues anchored to a paragraph's text and revision.
   - **The check scheduler,** a state machine on an injected clock. Inputs: text changes,
     caret moves, focus changes, pause and resume. It decides when a paragraph is checked,
     cancels a check whose paragraph changed, and drops results for text that is no longer
     there.
   - **The diff:** token-level edits between a paragraph and an engine's output.
   - **The edit guard** (below), which decides which edits become suggestions.
   - **Engine routing:** which engine serves a request, and what happens when it can't run.
   - **The never-touch list** and per-app settings, in a versioned storage format.
   - **The engine interface and the text-access interface,** declared here, implemented
     elsewhere.
   - **The remote engine clients** (Ollama or OpenAI-compatible for the Mac Studio, the
     Anthropic API for Claude), which need only Foundation networking.
2. **The platform layer for macOS 27.** Every Accessibility call, private attribute and
   `#available` check lives here.
   - **Text access:** the focused element of the frontmost app, its value, selection and
     bounds for a range, change notifications, and writing a replacement.
   - **The Apple engine:** Foundation Models with the general use case, permissive guardrails
     for content transformations, and greedy sampling.
   - **Language and words:** language detection constrained to English, Dutch and French; word
     lookups (spelling, part of speech, lemma) for the edit guard.
   - **Observers:** app activation, Apple Intelligence availability, thermal state.
3. **The app target.** The composition root, the status item, the overlay and its cards, the
   panel, Settings, hotkeys, launch at login and the Keychain. No business rules.

### Text access contract

Names are left to the builder.

- **Capabilities per app,** decided by the feasibility check (finding 7) and probed at run
  time: read, range bounds, the field's frame, a clean write, or nothing. A write is clean only
  if ⌘Z undoes exactly that change and the formatting around it survives. An app without a
  clean write is read-only: Copy instead of Accept. Skald does only what an app supports and
  says what it can't do there.
- **Two ways to read a field.** Most fields answer Accessibility's character ranges (value,
  selection, a string and bounds for a range). Some answer only through text markers, such as
  Mail's compose area (WebKit). Skald reads those through text markers: the field's text, and the selection as UTF-16 offsets measured as
  the lengths of marker ranges from the field's start. It decides per field which source
  places the caret, and keeps that source while the field lives. Text markers give no cheap
  way to read a window around the caret, so a text-marker field longer than the read limit
  isn't read at all (a reply above a long quoted thread, for example).
- **Web areas.** When the focused element is a web area, it is a field only if the element
  at its selection's start marker has an editable ancestor; the field is that ancestor
  (Mail's compose area is its own). A page being read is never a field. Zen's rich-text
  editors need no special route: focused, they are ordinary text areas (finding 7).
- **Two ways to write a clean replacement,** per app, each enabled only where the feasibility
  check measured it as clean:
  - **Accessibility:** select the range, then set the selected text (Notes, TextEdit).
  - **Paste,** where an app reads but ignores or misplaces Accessibility writes (Electron
    apps, Firefox), and in fields read through text markers (Mail): select the range
    through Accessibility and verify the selection; put the replacement on the clipboard,
    marked transient and concealed so clipboard managers skip it; post ⌘V to that app alone;
    wait until the field holds the paragraph with the replacement applied. Right before ⌘V,
    Skald checks again that the app is still frontmost, the focused element is the same one
    and the selection still covers the range; any change aborts before anything is pasted.
    It pastes only after watching the whole field for 1.5 s without a change (its length,
    the text Skald reads from it and its selection are the same at the start and at the end
    of that interval, and no change notification arrived in between), so the paste gets an
    undo step of its own in apps that merge edits made close together (Slack).
    Notifications can arrive late, so the comparison, not the absence of a notification, is
    the proof. It doesn't paste when the clipboard holds content it can't put back
    faithfully (concealed or promised data), or when the clipboard changed since Skald saved
    it; the suggestion then offers Copy.
  - **The clipboard after a paste.** An abort before ⌘V is posted restores the clipboard at
    once: nothing can paste. Once ⌘V is posted, the clipboard goes back to what it held only
    once the field shows the replacement, which proves the app consumed the paste, and only
    while the clipboard still holds Skald's replacement: if the user or another app copied
    something meanwhile, that newer content stays. When the field shows anything else after
    ⌘V, or nothing within 3 s, the accept is reported as unconfirmed and the card says the
    clipboard now holds the fix. Skald keeps watching that field and puts the old content back if the replacement
    appears; otherwise the old content is not restored, neither after a deadline nor when
    Skald quits, so a paste the app handles late inserts the fix, never the old clipboard
    (which may hold a password).
  - **A paste can land on changed text.** If the user clicks or types in the target app in
    the instant between Skald's last check and the app handling ⌘V (about 25 ms in the
    probe), the paste can land somewhere else in the field or app. Skald can't prevent
    this. It sees the field show something other than the expected paragraph and reports
    the accept as unconfirmed, as above; ⌘Z undoes the paste like any other edit. Michael
    accepted this risk (2026-11-06).
  - **The caret.** After a write, and after an abort that had already moved the selection,
    Skald puts the caret back where the user had it (shifted by the length change when it
    was after the range), but only while the field is still focused and its selection is
    still the one Skald left. If the user moved it meanwhile, Skald leaves it alone.
  - **Typing right after an accept** in an app that merges edits made close together
    (Slack) may join the accept's undo step: Skald can't mark where a step ends. The ⌘Z
    right after an accept still undoes exactly the fix. Michael decided (2026-11-06) that
    Slack keeps paste writes even if acceptance shows the merge; it is then a recorded
    limitation, like the app's own merging of his typing.
- **Snapshots** of the focused field: its text, selection and an identity stable while the
  field lives. Reads are bounded: a field longer than a limit is checked only around the caret.
- **Bounds** for a character range, in screen coordinates, used to draw underlines.
- **Replace** a range only if it is still the same field and the whole paragraph the issue was
  computed from is unchanged, not just the flagged words; otherwise the replacement is refused
  and the issue dropped. ("They is ready" → "are" must not apply after "They" became "He".)
- **Change events** from Accessibility notifications. Every probed app sends them (finding
  7), so there is no poll; an app that sends none is checked only when its field gains
  focus.
- **Never:** secure text fields, excluded apps, synthetic mouse events, or any synthetic
  keystroke except a paste write's single ⌘V, posted to the target app only.

A fake implementation drives the core's tests.

### Engine contract

- **Requests:** check a paragraph (language given), or transform a text (Fix or one of the
  rewrites, language given).
- **Answers:** the full output text, or a typed failure: unavailable (with a reason such as
  "Apple Intelligence is off" or "Mac Studio unreachable"), refused, timed out, cancelled.
- **Cancellation** is cooperative and prompt.
- **Routing:**
  - Checking while typing always uses This Mac. If it can't run, Skald falls back to spelling
    only and the status item says why.
  - The panel uses its default engine, This Mac as shipped, and lets the user pick another per
    request. If the Mac Studio is unreachable, the panel says so and offers This Mac or Claude.
    Claude is never used unless picked for that request or set as the panel's default.

### The quality bar

- Version checks and Accessibility calls live only in the platform layer.
- No central object that every component reaches into. Each component has one responsibility
  and receives its dependencies explicitly.
- Coordination is event-driven. A timeout bounds a wait; it never lets things settle.
- Every Accessibility call runs off the main actor and off Swift's cooperative pool, with a
  timeout.
- `@unchecked Sendable` and `nonisolated(unsafe)` only with a stated reason.
- Every scheduler transition, routing rule and edit-guard rule has a test with exact expected
  values.

## How it works

### Checking while typing

1. Skald follows the focused text field of the frontmost app, unless the app is excluded or the
   field is secure.
2. After a pause in typing (builder's value, starting near 700 ms), the scheduler picks the
   paragraph around the caret. Unchanged paragraphs are not checked again.
3. **Spelling** comes first and immediately, from `NSSpellChecker` in the paragraph's language.
   Spelling flags go through the same edit guard as model edits. Once the model's result for the
   paragraph arrives, a spelling flag on a word the model left unchanged is withdrawn.
4. **The model check** runs next: one request at a time; a newer pause cancels an older request.
   The instruction is short and names the paragraph's language (finding 2).
5. **The result** goes through the diff and the edit guard. Surviving edits become issues,
   anchored to the paragraph's text. If the paragraph changed while the check ran, the result is
   dropped.
6. **Underlines** are drawn by a transparent overlay that follows the field's bounds through
   scrolling, resizing and window moves, and hides when the field loses focus. In an app whose
   range bounds are missing or unreliable but whose field frame is known, a small badge at the
   field's corner shows the number of issues and opens them as a list of cards. Without either,
   the app gets the panel only.
7. **A card** opens from an underline: the change with context, and Accept (↩), Ignore, and
   Never flag this word. Accept replaces exactly the flagged range through text access.

Paragraphs are bounded by line breaks. Very long fields are checked only around the caret.

### The edit guard

The model and the spell checker propose; the guard decides. It is one component, used by both.

**The principle.** A fix corrects what is wrong in the user's own words: spelling, accents,
agreement, a wrong word form, a wrong function word, wrong punctuation. The guard drops anything
that replaces, translates or restyles text that was already correct, including borrowed English
words used correctly in Dutch or French, Belgian usage, a tense the writer chose, and an informal
style. Correcting the spelling or inflection of a borrowed word is a fix; replacing the word is
not.

**The contract is the outcomes below, not any one rule.** Each row is a test case. Where a rule
of thumb and a row disagree, the row wins.

| Proposed edit | Context | Outcome |
|---|---|---|
| "went" → "gone" | "I've went through the logs" | keep |
| "Hun" → "Zij" | "Hun hebben de migratie…" | keep |
| "als" → "dan" | "sneller als de oude" | keep |
| "est" → "sont" | "Les serveurs … est à jour" | keep |
| "word" → "wordt" | "de back-up word elke nacht…" | keep |
| "regarderais" → "regarderai" | "Je regarderais ça demain matin" | keep |
| "gedownloaded" → "gedownload" | "Ik heb de nieuwe versie gedownloaded" | keep |
| "friday" → "Friday" | "before friday?" | keep |
| "voorvallen" → "voorkomen" | "mag niet meer voorvallen" | drop |
| "passent" → "se déroulent" | "les tests passent sans problème" | drop |
| "proprement" → "correctement" | "redémarrent proprement" | drop |
| "gemerged" → "gemerkt" | "de fix … gemerged" | drop |
| "mergé" → "fusionné" | "J'ai mergé le correctif" | drop |
| "tiens" → "tiendrai" | "je vous tiens au courant" | drop |
| a final "." added | "ping me if the canary looks off" (informal, no final periods) | drop |
| spelling flag on "reviewt" | "Northwind reviewt die de week erna" | drop |
| spelling flag on "Sidekiq-jobs" | "de Sidekiq-jobs lopen weer" | drop |
| spelling flag on "mergé" | "J'ai mergé le correctif" | drop |
| spelling flag on "Talos", "Pieter" | names | drop |
| any edit touching a never-touch word, a number, a URL or code | — | drop |

**Whole results.** A result whose language differs from the input's, or that changes more than a
set share of the paragraph (a rewrite, not a fix), is discarded entirely.

**The mechanism is the builder's.** Rules of thumb to start from: misspellings and accents are
fixes; function words come from word lists (Dutch has no word classes in Natural Language, see
finding 6); a different content word is a replacement unless the two forms are near-homophones;
names, numbers, URLs and code are never touched. For an edit the rules can't decide, the guard
may ask the same on-device model a short yes-or-no question. That confirmation obeys the same
gates as model checks: Apple Intelligence available, no thermal pause, and model checks on for
that language. Without it, an undecidable edit is dropped. Spelling-only evaluation runs with
confirmation off.

**Judged on data.** Every row above is a unit test. The evaluation set's clean paragraphs include
borrowed-word, tense-change and informal-style traps in all three languages, and on the spike's
stored outputs the guard keeps every true fix the model made and drops the six false alarms in
finding 3.

### The panel

- **Opens** with a global hotkey on the selection, or the current paragraph. It never steals the
  field's text: it works on a copy and writes back only on Replace.
- **Actions:**
  - **Fix** splits the selection into paragraphs, checks each one in its own language exactly as
    checking while typing does (same request, same guard), and puts the result back together
    with the original paragraph breaks.
  - **The rewrites** Clearer, Shorter, More formal and Friendlier skip the guard, because the
    user asked for new wording. A selection in one language is rewritten as a whole; a selection
    that mixes languages is rewritten paragraph by paragraph, each in its own language.
- **Shows** the result as a diff against the original. Replace writes it back through text
  access; Copy puts it on the clipboard. If the app can't be written to, Replace is replaced by
  Copy.
- **Engine picker:** This Mac, Mac Studio, Claude, with the default from Settings.

### Languages

- Detected per paragraph with Natural Language, constrained to English, Dutch and French. Very
  short paragraphs inherit the field's last confident language.
- Belgian usage is correct: the instruction says so, and the evaluation set includes it.
- English: British spelling is the default and American spelling is accepted too. A word counts
  as misspelled only if both dictionaries reject it.
- Spelling uses the macOS dictionaries for the detected language. Words added to the never-touch
  list are also learned by the spell checker for Skald's own checks.

### Settings

- **General:** launch at login, the panel's hotkey, pause for an hour.
- **Apps:** a list of apps with Skald on or off. Off by default: terminals, code editors and
  password managers.
- **Words:** the never-touch list.
- **Languages:** model checks on or off per language. A language that misses the evaluation's
  precision bar ships with them off (see Verification).
- **Engines:** the panel's default engine. Mac Studio: Ollama or OpenAI-compatible base URL and
  model; as shipped it has no address and stays out of the panel's picker until one is set.
  Claude: API key (Keychain) and model, `claude-opus-5-5` as shipped, as in Muninn.

### Permissions, availability and failures

- **First launch** asks for Accessibility, with a short explanation, and waits for the grant.
- **Apple Intelligence off or the model not ready:** spelling only, and the status item and
  Settings say why.
- **An app that doesn't answer Accessibility** within the timeout is skipped for that check and
  marked after repeated timeouts; Skald never retries in a loop.
- **Thermal state serious or critical:** model checks pause until it recovers; spelling
  continues.

### Logging

Unified logging under `com.michaelrigart.skald`: events, timings, engine and failure categories.
Never user text, never the never-touch list, never the API key.

## Verification

- **Core unit tests** (Swift Testing) pin exact expected values:
  - **The scheduler:** a check starts after the pause on the injected clock; typing restarts
    the wait; a caret move to another paragraph schedules that one; a newer request cancels the
    older one; a result for changed text is dropped; pause stops everything.
  - **The diff:** exact edits for insertions, deletions, replacements and accents.
  - **The edit guard:** every row of its outcome table, plus the whole-result rules.
  - **Fix in the panel:** a selection with an English and a Dutch paragraph is checked as two
    requests, each with its own language, and reassembled with the original breaks.
  - **Routing:** checking while typing never goes remote; the panel's fallbacks; Claude only
    when picked.
  - **Storage:** round-trips; a future version is refused and never overwritten.
  - **Replace:** refused when the field's text at the range differs, when the field is a
    different one, and when the paragraph changed elsewhere while the flagged words stayed the
    same.
- **The evaluation set,** a separate test target that needs Apple Intelligence and runs outside
  the unit tests:
  - Seeded from the appendix and grown to at least 50 paragraphs per language, a third of them
    clean, in Michael's register. Synthetic text only: no customer content and no real company
    names.
  - **Split:** a tuning part (the seed and about half of the new paragraphs) sets the guard's
    thresholds; a held-out part only grades. The guard is never tuned on the held-out part.
  - **Review:** an agent drafts the new paragraphs and references. Michael reviews the Dutch and
    French references and the clean paragraphs; until he has, results are provisional.
  - Reports recall, precision, clean false alarms and latency per language, with the edit guard
    on, for the model path and separately for spelling only.
  - **Bar, per language, on the held-out part:** precision at least 0.95, at most one clean
    paragraph flagged, recall at least 0.90, p90 latency under 1 s. Spelling only: precision at
    least 0.95.
  - **A miss:**
    - A language that misses the model path's precision or clean-paragraph limit ships with
      model checks off for it (spelling only), and Settings says why.
    - A language whose spelling-only precision also misses ships with checking while typing off
      for it; the panel still works there.
    - A recall miss with precision met ships, and so does a latency miss; both are noted in the
      merge request with the measured values.
  - Run before each release and after every macOS update.
- **A probe** for Debug builds, started with a launch argument as in Linger and Hulder. Run from
  `/Applications`, it logs per app: the focused element's role, whether value, selection, bounds
  and writes work, whether a write can be undone, and change-notification support. It never logs
  text. It is run again on every new macOS release.
- **Manual acceptance on Michael's Mac:**
  - checking while typing in Notes, Mail, Zen (a plain field and Basecamp's editor), and each
    Electron app the feasibility check marked as supported;
  - accepting, ignoring and never-flagging; ⌘Z after an accept, in an app written through
    Accessibility and in one written by paste, with the clipboard unchanged afterwards and
    the caret back where it was; in Slack, typing straight after an accept, then ⌘Z;
  - the panel's Fix and rewrites on This Mac and Claude, and on the Mac Studio once it is
    available (until then its client is tested against a stub server);
  - `powermetrics` during ten minutes of normal writing: GPU at idle level, no sustained CPU
    rise;
  - Apple Intelligence off: spelling only, with the reason shown;
  - secure fields and excluded apps are never read (checked with the probe's log).

## Delivery

- **v1 deliverable:** Skald.app, built locally, installed in `/Applications`, launching at login
  and replacing Grammarly.
- **The plan's first task is a feasibility check on macOS 27.2** with a signed bundle run from
  `/Applications`, before any user-interface work. For Notes, Mail, TextEdit, Zen (an input, a
  textarea, and the rich-text editors of Basecamp and GitLab), Proton Mail, Signal, Slack and
  Obsidian, it records:
  1. whether the focused field's text, selection and bounds for a range can be read, and how
     Electron and Firefox need to be asked (`AXManualAccessibility`,
     `AXEnhancedUserInterface`);
  2. whether a range can be replaced, whether ⌘Z undoes exactly that change, whether the app's
     earlier undo history survives, and whether rich-text formatting around it survives;
  3. which change notifications arrive, and how quickly;
  4. whether bounds stay correct through scrolling, zoom and window moves;
  5. Apple's model through Foundation Models inside the signed app: availability and latency,
     with the spike's prompt and scorer re-run from the stored fixtures;
  6. the cost of asking Electron and Firefox for their accessibility trees: the target app's CPU,
     idle and while typing, with and without the attribute set, and whether
     `AXEnhancedUserInterface` disturbs window moves or animations. Skald sets only what each app
     needs.
- **Michael at the Mac.** The check needs him for about half an hour, to focus fields in each
  app and grant Accessibility after rebuilds.
- **Stop and bring it to Michael** if:
  - Zen's rich-text editors can be neither read nor written: the alternatives (a browser
    extension, or pasting through the clipboard with synthetic keystrokes) are design changes;
  - an app class he relies on (Electron mail or chat) supports reading but not writing: the
    choice between suggestions he copies and synthetic paste is his;
  - Foundation Models inside the app differs materially from the spike;
  - Proton Mail, Signal or Slack get neither underlines nor the badge (panel only), which would
    break Michael's decision that Electron apps are covered;
  - forcing accessibility on costs noticeable CPU in an app he keeps open all day.
- **At the stop gate (2026-11-05)** the probe showed Electron apps and Zen's text areas
  reading but not taking Accessibility writes, and Zen's rich-text editors not readable as
  fields. Michael chose paste writes for the first and an investigation of Firefox's text
  markers for the second (see Decisions). The text access contract above records the result.
- **The gate on 2026-11-06,** after the probe's last runs (finding 7): nothing on the list
  triggers. Zen's rich-text editors turned out to be ordinary text areas once focused, read and
  written like its textareas, so the choice between text markers, the panel only and an
  extension didn't arise. Slack and Signal take paste writes; Proton Mail gets the badge with
  Copy only. Apple's model inside the app stays within the bounds (recall 0.97, precision 0.83,
  3 of 12 clean paragraphs flagged). Electron apps with accessibility on idle at 1–2 % of a
  core; the cost while typing is measured at acceptance.

## Left to the builder

- Code structure inside the three parts, and all names.
- The storage format, as long as it is versioned and readable.
- The hotkey mechanism and default hotkey.
- The pause length, paragraph-length limits, timeouts and edit-guard thresholds, set with the
  evaluation set and the probe.
- The overlay's hit-testing and the card's visual design, within the anti-goals (no focus
  stealing, no interference with typing).
- The icon artwork and the panel's visual design.
- The model for the Mac Studio, chosen by a bake-off on the evaluation set once it is
  available.

## Decisions

**Michael decided (2026-11-01 and 2026-11-02):**

- Build his own Grammarly replacement for his Mac.
- Languages: English, Dutch and sometimes French.
- He writes in native apps, Electron apps and the browser, and Skald must cover all three.
- The Mac must not be loaded during his day-to-day development work. The Neural Engine is the
  preferred place for the model.
- Remote engines in the style of Muninn: the Mac Studio and Claude. The Mac Studio is not
  available now.
- The name is Skald.
- A throwaway spike before this spec (its results are in "Measured on macOS 27.2").
- Continue the work overnight without him (2026-11-02, 01:00).

**Michael decided at the feasibility stop gate (2026-11-05):**

- Apps without a clean Accessibility write (the Electron apps, Zen's text areas) get Accept
  through a synthetic paste: select through Accessibility, verify the selection, put the fix
  on the clipboard marked so clipboard managers skip it, post ⌘V, restore the clipboard. Each
  app gets it only where the probe shows that the paste replaces exactly and ⌘Z undoes
  exactly; the others get Copy only.
- Zen's rich-text editors (Basecamp, GitLab): the probe first tries Firefox's text-marker
  interface, the one VoiceOver uses; he then chooses between that, the panel only and a
  browser extension.
- Builds are signed with his Apple Development certificate, so the Accessibility grant
  survives rebuilds.
- Distribution (release script, verification, cask, CI) gets its own spec and plan, released
  only after v1's remaining tasks.

**Michael decided on the paste write's limits (2026-11-06):**

- The risk of a paste landing in the wrong place, when he clicks or types in the instant after
  Skald's last check, is accepted: it is reported and undone with ⌘Z.
- His old clipboard comes back only once the paste is seen in the field; an unconfirmed paste
  leaves the fix on the clipboard for good, with no deadline and no restore at quit.
- Slack keeps paste writes even if typing straight after an accept joins its undo step.

**Claude's calls, for Michael to check:**

- Checking while typing always runs on This Mac; the remote engines serve the panel only.
- Apple's on-device model is the only local engine in v1; open models wait for one that beats
  it on the evaluation set (finding 4).
- Precision over recall: a missed error is better than a false alarm, hence the edit guard and
  the evaluation bar of precision 0.95.
- Terminals, code editors and password managers are off by default.
- Deployment target 27.0, bundle identifier, signing, toolchain, repository and license follow
  the suite's conventions.
- Spelling flags go through the edit guard and are withdrawn when the model leaves the word
  alone; spelling only is scored separately.
- An app without a clean write is read-only (Copy instead of Accept). Without range bounds, a
  badge with the issue count; without a field frame, the panel only.
- The evaluation set has tuning and held-out parts, and its bar is per language. A language that
  misses precision ships with model checks off, or with checking while typing off if spelling
  also misses.
- Replace re-checks the whole paragraph, not just the flagged words.
- Fix works paragraph by paragraph, each in its own language; mixed-language rewrites too.
- The edit guard is specified by an outcome table rather than by rules: it drops replacements,
  translations, tense changes and added formality, keeps corrections (including of a borrowed
  word's inflection), and may ask the on-device model to confirm an undecidable edit.
- British English by default, American accepted (his own writing uses British spelling).
- The Mac Studio engine is built and tested against a stub server; its acceptance waits for the
  Studio.
- The evaluation data uses fictional company names and the spec names no machine details,
  because the repository will be public.
- After an accept, the caret goes back to where Michael had it, when he hasn't moved it.

## Appendix: seed evaluation set

The spike's 36 paragraphs: `text` is the input, `ref` the reference correction (identical for
clean paragraphs). The company names Brightline and Northwind are fictional replacements made
after the spike.

```jsonl
{"id":"en1","lang":"en","text":"Hi Sarah, thanks for the quick reply. I've went through the logs and their is definitely something wrong with the backup job on the staging server.","ref":"Hi Sarah, thanks for the quick reply. I've gone through the logs and there is definitely something wrong with the backup job on the staging server."}
{"id":"en2","lang":"en","text":"The new deployment pipeline run every night at two, but it's status isn't reported anywhere yet.","ref":"The new deployment pipeline runs every night at two, but its status isn't reported anywhere yet."}
{"id":"en3","lang":"en","text":"Could you send me the the updated contract before friday? I want to review it with Pieter on monday.","ref":"Could you send me the updated contract before Friday? I want to review it with Pieter on Monday."}
{"id":"en4","lang":"en","text":"We have tested the migration on a copy of production, and everything seem to work, allthough the indexes took longer then expected.","ref":"We have tested the migration on a copy of production, and everything seems to work, although the indexes took longer than expected."}
{"id":"en5","lang":"en","text":"Each of the clusters have its own ingress controller, which make debugging a lot easier.","ref":"Each of the clusters has its own ingress controller, which makes debugging a lot easier."}
{"id":"en6","lang":"en","text":"I recieved your invoice yesterday. Accounting will process it this week, so you should recieve the payment by the end of the month.","ref":"I received your invoice yesterday. Accounting will process it this week, so you should receive the payment by the end of the month."}
{"id":"en7","lang":"en","text":"Lets schedule a call for tomorrow afternoon to discuss the the roadmap and who's responsible for which part.","ref":"Let's schedule a call for tomorrow afternoon to discuss the roadmap and who's responsible for which part."}
{"id":"en8","lang":"en","text":"The client asked if we could reduce the number of alerts, because they get to many notifications at night.","ref":"The client asked if we could reduce the number of alerts, because they get too many notifications at night."}
{"id":"enc1","lang":"en","text":"I merged the fix for the Talos upgrade into main. The kubelet config now pins the cgroup driver, so the nodes come back cleanly after a reboot.","ref":"I merged the fix for the Talos upgrade into main. The kubelet config now pins the cgroup driver, so the nodes come back cleanly after a reboot."}
{"id":"enc2","lang":"en","text":"Quick update: the Rails app is on 8.1, Sidekiq jobs are green, and I've rotated the pg credentials in 1Password.","ref":"Quick update: the Rails app is on 8.1, Sidekiq jobs are green, and I've rotated the pg credentials in 1Password."}
{"id":"enc3","lang":"en","text":"Thanks for joining today's call. As agreed, Brightline will deliver the first draft of the integration by the 14th, and Northwind will review it the following week.","ref":"Thanks for joining today's call. As agreed, Brightline will deliver the first draft of the integration by the 14th, and Northwind will review it the following week."}
{"id":"enc4","lang":"en","text":"lgtm, ship it. ping me if the canary looks off","ref":"lgtm, ship it. ping me if the canary looks off"}
{"id":"nl1","lang":"nl","text":"Hallo Jan, de back-up word elke nacht om twee uur uitgevoerd, maar gisteren is er iets fout gegaan.","ref":"Hallo Jan, de back-up wordt elke nacht om twee uur uitgevoerd, maar gisteren is er iets fout gegaan."}
{"id":"nl2","lang":"nl","text":"Ik heb de nieuwe versie gisteren gedownloaded en het probleem is nog steeds niet opgelost.","ref":"Ik heb de nieuwe versie gisteren gedownload en het probleem is nog steeds niet opgelost."}
{"id":"nl3","lang":"nl","text":"De server is veel sneller als de oude, maar het geheugengebruik is eigelijk hoger.","ref":"De server is veel sneller dan de oude, maar het geheugengebruik is eigenlijk hoger."}
{"id":"nl4","lang":"nl","text":"Kan je mij laten weten wanneer het contract getekend is? Dan stuur ik onmiddelijk de factuur.","ref":"Kan je mij laten weten wanneer het contract getekend is? Dan stuur ik onmiddellijk de factuur."}
{"id":"nl5","lang":"nl","text":"Wat er gisteren gebeurt is, mag niet meer voorvallen. Ik stel voor dat we de alerts beter configureren.","ref":"Wat er gisteren gebeurd is, mag niet meer voorvallen. Ik stel voor dat we de alerts beter configureren."}
{"id":"nl6","lang":"nl","text":"Hun hebben de migratie nog niet getest, dus we wachten best tot volgende week.","ref":"Zij hebben de migratie nog niet getest, dus we wachten best tot volgende week."}
{"id":"nl7","lang":"nl","text":"De documentatie moet duidelijker worden, want nieuwe collega's begrijpen de setup niet. Wanneer word het aangepast?","ref":"De documentatie moet duidelijker worden, want nieuwe collega's begrijpen de setup niet. Wanneer wordt het aangepast?"}
{"id":"nl8","lang":"nl","text":"De klant is zeer geintereseerd in de nieuwe functionaliteit en wil volgende week een demo.","ref":"De klant is zeer geïnteresseerd in de nieuwe functionaliteit en wil volgende week een demo."}
{"id":"nlc1","lang":"nl","text":"Ik heb de fix voor de Talos-upgrade gemerged. De nodes komen nu proper terug na een reboot.","ref":"Ik heb de fix voor de Talos-upgrade gemerged. De nodes komen nu proper terug na een reboot."}
{"id":"nlc2","lang":"nl","text":"Dag Pieter, bedankt voor je snelle antwoord. Ik bekijk het morgen en laat je iets weten tegen vrijdag.","ref":"Dag Pieter, bedankt voor je snelle antwoord. Ik bekijk het morgen en laat je iets weten tegen vrijdag."}
{"id":"nlc3","lang":"nl","text":"De pipeline draait groen, de Sidekiq-jobs lopen weer en de credentials staan in 1Password.","ref":"De pipeline draait groen, de Sidekiq-jobs lopen weer en de credentials staan in 1Password."}
{"id":"nlc4","lang":"nl","text":"Zoals afgesproken levert Brightline de eerste versie op tegen de 14e, en Northwind reviewt die de week erna.","ref":"Zoals afgesproken levert Brightline de eerste versie op tegen de 14e, en Northwind reviewt die de week erna."}
{"id":"fr1","lang":"fr","text":"Bonjour Marie, je vous est envoyé le contrat hier, mais je n'ai pas encore reçu de réponse.","ref":"Bonjour Marie, je vous ai envoyé le contrat hier, mais je n'ai pas encore reçu de réponse."}
{"id":"fr2","lang":"fr","text":"La sauvegarde a échoué cette nuit a cause d'un problème de disque sur le serveur de test.","ref":"La sauvegarde a échoué cette nuit à cause d'un problème de disque sur le serveur de test."}
{"id":"fr3","lang":"fr","text":"Les serveurs de production est maintenant à jour, et les tests passent sans problème.","ref":"Les serveurs de production sont maintenant à jour, et les tests passent sans problème."}
{"id":"fr4","lang":"fr","text":"Pouvez-vous me dire ou se trouve la documentation de l'API ? Je ne la trouve pas sur le wiki.","ref":"Pouvez-vous me dire où se trouve la documentation de l'API ? Je ne la trouve pas sur le wiki."}
{"id":"fr5","lang":"fr","text":"La facture que je vous ai envoyé la semaine dernière contient une erreur de TVA.","ref":"La facture que je vous ai envoyée la semaine dernière contient une erreur de TVA."}
{"id":"fr6","lang":"fr","text":"Nous avons deja testé la migration, mais certaines requêtes sont encore trop lente.","ref":"Nous avons déjà testé la migration, mais certaines requêtes sont encore trop lentes."}
{"id":"fr7","lang":"fr","text":"Le client voudrait moins d'alertes la nuit, ces vraiment pénible pour son équipe.","ref":"Le client voudrait moins d'alertes la nuit, c'est vraiment pénible pour son équipe."}
{"id":"fr8","lang":"fr","text":"Merci pour votre retour. Je regarderais ça demain matin et je vous tiens au courant.","ref":"Merci pour votre retour. Je regarderai ça demain matin et je vous tiens au courant."}
{"id":"frc1","lang":"fr","text":"Bonjour Thomas, merci pour la réunion de ce matin. Comme convenu, nous livrerons la première version d'ici le 14. Le budget reste à septante mille euros.","ref":"Bonjour Thomas, merci pour la réunion de ce matin. Comme convenu, nous livrerons la première version d'ici le 14. Le budget reste à septante mille euros."}
{"id":"frc2","lang":"fr","text":"J'ai mergé le correctif pour l'upgrade de Talos. Les nœuds redémarrent proprement maintenant.","ref":"J'ai mergé le correctif pour l'upgrade de Talos. Les nœuds redémarrent proprement maintenant."}
{"id":"frc3","lang":"fr","text":"Le pipeline est vert, les jobs Sidekiq tournent à nouveau et les identifiants sont dans 1Password.","ref":"Le pipeline est vert, les jobs Sidekiq tournent à nouveau et les identifiants sont dans 1Password."}
{"id":"frc4","lang":"fr","text":"Pas de souci, on en reparle lundi. Bon week-end !","ref":"Pas de souci, on en reparle lundi. Bon week-end !"}
```
