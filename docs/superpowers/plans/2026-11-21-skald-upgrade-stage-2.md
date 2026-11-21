# Skald Upgrade, Stage 2 (Overlay) Implementation Plan

**Status:** In progress

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. In this repository the `plan-run` skill runs plans and takes precedence over both.

**Goal:** Underlines in three colours by category with a legend; a card that names the kind of issue, offers alternatives and can hide a kind; a counter in every checked field and review from the keyboard; underlines that hide on a scroll and come back in the right place; a menu line where Skald can't work, and VoiceOver labels.

**Architecture:** Skald classifies every kept edit itself (`IssueClassifier` → `IssueKind`, three fixed `IssueCategory` values) and the pipeline publishes it on `Issue`, with the spell checker's other guesses as `alternatives`, a `checked` flag on the snapshot, and hidden kinds filtered out. Two pure state machines in `SkaldCore` carry the new behaviour: `ScrollSettle` (hide on scroll, show once reads agree across twice the app's measured lag) and `ReviewMode` (a position in the text, keys, the ways out). `OverlayController` executes their actions; the keys are Carbon hotkeys held only while the mode is open. The lag per app comes from a probe mode run first.

**Tech Stack:** Swift 6, Swift Testing, SwiftPM packages `SkaldCore` (Foundation and Observation only) and `SkaldPlatform27`, the AppKit/SwiftUI app target, xcodegen, Carbon hotkeys.

**Spec:** `docs/superpowers/specs/2026-11-20-skald-upgrade-design.md`, "Stage 2: overlay" and the sections it relies on (Goals 4 to 8, Non-goals, Anti-goals, Constraints, "Left to the builder"). v1's rules: `docs/superpowers/specs/2026-11-02-skald-design.md`. Stage 1 is built; nothing here changes an engine, a route or what is sent.

**Base:** `feat/skald-overlay`, started from `feat/skald-upgrade` at `d4c47fe`. When `feat/skald-upgrade` moves, merge it in (never rebase pushed work).

**Order:** the tasks run serially, 1 to 12; each `Depends on:` names the tasks whose interface it uses.

**Prior art read (spec: "the builder reads its overlay code"):** Harper Desktop (`harper-desktop/src-tauri/src`, master, read 2026-11-21) re-reads every range's bounds on a 16 ms timer, has no scroll handling, no stale-bounds handling, no clipping, no keyboard navigation and no accessibility labels. It hides highlights only while the app's window frame has changed in the last 150 ms. Nothing of it is taken: its polling is what the spec rules out. Its one window per screen and `orderFrontRegardless` match what v1 already does.

## Global Constraints

- macOS 27, Swift 6. `SkaldCore` imports only Foundation and Observation; OS-specific APIs and `#available` live in `SkaldPlatform27`; the app may use AppKit and SwiftUI.
- Text offsets are UTF-16 units (`TextRange`), never `Character` counts.
- No user text and no secret in logs, on disk or printed. The scroll probe writes app identifiers, scroll kinds and milliseconds, nothing else. Never read, print or log the Claude key.
- **Memory:** no new process, no model, no timer that runs while nothing happens, no polling, no word list. Every read this plan adds is started by an event (a scroll, a hover, a key) and is bounded. No app gets `AXEnhancedUserInterface` that doesn't already.
- A hidden underline is better than a wrong one.
- The card never takes keyboard focus; the overlay never activates Skald.
- Outside review mode Skald holds none of →, ⇥, ←, ↩, ⌫, esc.
- The model is never asked for a category or an explanation: the engine contract and the prompts stay byte for byte.
- Tests and Eval data are synthetic and hold no real company names.
- Every command below runs outside the agent sandbox, prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Every compiling `xcodebuild` passes a `-derivedDataPath` ending in `.noindex`.
- Suites, by what a task changed (implementers run only these; the controller runs everything at the end):
  - Core: `swift test --package-path Packages/SkaldCore`
  - Platform: `swift test --package-path Packages/SkaldPlatform27`
  - App: `mise exec -- xcodegen generate`, then `xcodebuild test -project Skald.xcodeproj -scheme Skald -derivedDataPath build/dd.noindex -quiet -only-testing:SkaldTests`
- Commits: imperative mood, no agent attribution, staged changes checked for secrets. A commit stages the task's listed files by path, never a directory.
- Live steps (controller only): never Send in Mail and never read real mail; do not touch Slack, Signal, Obsidian or Basecamp; never touch permission dialogs or Apple Intelligence settings; synthetic input only when the Mac's hardware has been idle for 8 s or more; no implementer runs a live step. `/Applications/Skald.app` is Michael's installed build: back it up before replacing it, restore it after, and say so in the report.

## Values this plan decides (spec, "Left to the builder")

| Item | Decision |
|---|---|
| Kinds | `spelling`, `capital`, `accent` (category Spelling); `punctuation` (Punctuation); `grammar`, `repeatedWord`, `verbForm` (Grammar). Titles: "Spelling", "Capital letter", "Accent", "Punctuation", "Grammar", "Repeated word", "Verb form". |
| Classification, first match wins | 1. the edit's words are the same on both sides → `punctuation`; 2. the same but for letter case → `capital`; 3. the same but for diacritics (case may differ too) → `accent`; 4. a spelling issue, or an original word the dictionary rejects → `spelling`; 5. a deleted single word equal, ignoring case, to the word before or after it → `repeatedWord`; 6. Dutch, one word for one word, equal once a final "dt", "d" or "t" is cut from each and at least two letters remain → `verbForm`; 7. `grammar`. "Words" are `EditGuard.words(in:)` without lowercasing. |
| Hideable kinds | `capital`, `accent`, `punctuation`, `repeatedWord`, `verbForm`. Never `spelling` or `grammar`. |
| Colours (sRGB) | Light: Spelling `#D55E00`, Grammar `#0072B2`, Punctuation `#4B0082`. Dark: Spelling `#FF8A4C`, Grammar `#56B4E9`, Punctuation `#FFE66D`. Chosen by simulation (Machado 2009, full protanopia, deuteranopia, tritanopia): every pair stays at least 0.3 apart in sRGB in every simulation; no third hue does that beside vermilion and blue, so Punctuation separates by lightness, and is also drawn dotted (2 pt on, 2 pt off). |
| Badge | At the bottom-right corner of every checked field whose app gives the field's frame. Zero issues: a grey tick at 60 % opacity, no click action. |
| "Checked" | `IssueSnapshot.checked`: not paused, and a spelling or model result has been stored for a paragraph of the focused field. |
| Alternatives | A spelling issue carries up to 2 more guesses after the first (three in all), each a guard-kept edit over the same range. |
| Review shortcut | `⌃⌥R` (`Hotkey(keyCode: 15, modifiers: control | option)`), setting `reviewHotkey`. Pressed again, it leaves the mode. |
| Review keys | → `124`, ⇥ `48` next; ← `123` previous; ↩ `36` accept; ⌫ `51` dismiss; esc `53` leave; no modifiers. All six register or the mode does not open. While an accept is applied all six stay held and only esc acts, so a ↩ can't reach the app mid-write. |
| Review, which issue | Next: the first issue starting after the position. Previous: the last starting before it. At either end the key does nothing. After an accept or a dismiss: the first remaining issue at or after the position, else the last before it, else the mode ends. An accept whose write is not confirmed ends the mode and leaves v1's card with its reason. In an app without a clean write, ↩ copies the fix and stays. |
| Own edits | An edit within 1 s of an accept's outcome is Skald's own (`ReviewMode.ownEditGrace`, on the injected clock); any other edit leaves the mode. |
| Scroll rule | `ScrollSettle(ceiling:)`. Reads every `ceiling` after the last scroll event; underlines show when a read taken `2 × ceiling` or more after the last scroll event equals the read before it. Then 3 more reads, one per `ceiling`; one that differs hides and starts over from that moment. After 20 reads without showing, it stops and stays hidden until the next text or caret change. `ceiling == nil` (unmeasured): hidden until the next text or caret change. |
| Lag ceiling | Per app: the largest lag measured, rounded up to 50 ms, at least 50 ms; nil when fewer than 20 gestures of any of the three kinds were measured or one never settled within 5 s. The table lives in `ScrollLag.ceilings` and holds only measured apps. |
| Which scrolls | Every `scrollWheel` event counts, whatever window is under the pointer: a page can scroll its text area from anywhere, and Skald doesn't ask which window got the event. |
| Hover check | Before a hover card opens, the word's bounds are read again; more than 2 pt from the drawn place on either axis, or unreadable, redraws instead. |
| Pause | Menu: "Pause for 30 Minutes", "Pause for an Hour". Settings keeps one button, "Pause for an Hour". |
| Menu lines | "Skald can't read text in this app" (the frontmost app answers no focused element), "Issues are listed at the badge here" (frame, no range bounds), "Skald can't show issues in this app" (neither; added, see Rulings). While checks go to Claude or Claude is in trouble, stage 1's line stays first and this one follows it; paused or without Accessibility, it isn't shown. |
| Legend | Menu: submenu "Underline Colours" with three items, each a coloured dot and the category's name. Settings: a new "Suggestions" pane with the legend, the hidden kinds and the review shortcut. |
| Labels | `"‹Category›: ‹original›, change to ‹replacement›"`; an insertion `"‹Category›: add ‹replacement›"`; a deletion `"‹Category›: remove ‹original›"`. Review steps announce the label and `"‹n› of ‹count›"`. |
| Settings storage | Version stays 2 (no value changes shape). New keys `hiddenKinds` (array of kind names, `[]`; an unknown name is dropped) and `reviewHotkey`. Changing `hiddenKinds` republishes without a recheck. |
| Memory | As stage 1: `/usr/bin/footprint -p Skald`, idle and after a TextEdit check, baseline (`d4c47fe`) against the new Release build; numbers go in the PR. |

## Rulings made while planning (inside the spec; listed in the PR)

- **Two "first lines".** Stage 1's review says the Claude line is first while a request can leave; stage 2 says the first line names an app Skald can't work in. The privacy line wins the first place and the app line follows it.
- **A third app line**, "Skald can't show issues in this app", for an app that gives text but neither range bounds nor a frame. The spec names two; Goal 8 ("says so when it can't work in an app") covers the third.
- **"Only esc is taken" while a write is applied** is read as "only esc acts": the other keys stay held, or a ↩ pressed during a paste would go to the app.
- **After an accept, with nothing after the position,** the mode goes to the last issue before it rather than ending while issues remain.
- **Punctuation is dotted as well as coloured,** because no three hues stay apart under all three deficiencies on a 2 pt line.

## Review Focus

1. **A review key that failed to register while the others did**: ↩ would then reach the app and could send a message. Expected: all six or none, and the mode stays closed. Task 10, `aKeyThatDoesNotRegisterKeepsTheModeClosedAndFreesTheRest`.
2. **A key still held after the mode ended by a way other than esc** (focus change, click elsewhere, a foreign edit, the last issue accepted, Skald paused, the overlay stopped). Expected: none held. Task 6, `everyWayOutClosesTheMode`; Task 10, `noKeyIsHeldOnceTheModeIsClosed`.
3. **A scroll in an app that never stops changing its bounds** (an animated page): reads without end are polling. Expected: 20 reads, then hidden and silent. Task 5, `readsStopAfterTheBound`.
4. **A hidden kind while its card is open or review mode stands on it.** Expected: the issue leaves the snapshot at once, the card closes, review moves on or ends. Task 4, `hidingAKindRepublishesWithoutIt`; Task 6, `theShownIssueVanishingMovesToTheNearest`.
5. **An alternative accepted after the paragraph changed, or an index out of range.** Expected: the write goes through v1's `expected` check, and a bad index is `.failed` without a write. Task 3, `acceptingAnAlternativeWritesItsText` and `anUnknownAlternativeIsRefused`.

---

## Baseline (controller, before Task 1)

```bash
mise exec -- xcodegen generate
xcodebuild -project Skald.xcodeproj -scheme Skald -configuration Release -derivedDataPath build/dd-baseline.noindex -quiet build
mkdir -p build/baseline && ditto build/dd-baseline.noindex/Build/Products/Release/Skald.app build/baseline/Skald.app
git rev-parse HEAD   # the baseline's commit
```

---

### Task 1: The scroll-lag probe

**Depends on:** none

**Files:**
- Create: `Packages/SkaldPlatform27/Sources/SkaldPlatform27/Probe/ScrollLagTrace.swift` (pure), `Packages/SkaldPlatform27/Sources/SkaldPlatform27/Probe/ScrollLagProbe.swift` (`#if DEBUG`)
- Modify: `Skald/AppDelegate.swift` (`--probe-scroll`, with `--drive`; Debug only, beside `--probe`), `LaunchMode` (the new argument resolves to `.probe` handling of its own case `.scrollProbe`)
- Test: `Packages/SkaldPlatform27/Tests/SkaldPlatform27Tests/ScrollLagTraceTests.swift`, `SkaldTests/LaunchModeTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum ScrollKind: String, Sendable, CaseIterable { case wheel, trackpad, momentum }
  /// One gesture: scroll events and bounds samples in time order, times from the probe's start.
  public struct ScrollLagTrace: Sendable {
      public static let quiet: Duration = .seconds(1)      // no change and no scroll for this long: settled
      public static let giveUp: Duration = .seconds(5)     // after the last scroll event: unsettled
      public init()
      public mutating func scrolled(_ kind: ScrollKind, at now: Duration)
      public mutating func sampled(_ bounds: CGRect?, at now: Duration)
      public var kind: ScrollKind?                          // the last event's kind
      /// From the last scroll event to the last sample that differed from the one before it; zero when none did.
      public var lag: Duration?                             // nil before any scroll
      public func isSettled(at now: Duration) -> Bool
      public func gaveUp(at now: Duration) -> Bool
  }
  public enum ScrollLagSummary {
      public static let gestures = 20
      /// nil with fewer than `gestures` lags or any nil (unsettled) among them; else the largest, up to the next 50 ms, at least 50 ms.
      public static func ceiling(_ lags: [Duration?]) -> Duration?
      /// The app's ceiling: the largest of its kinds', nil when any kind has none.
      public static func ceiling(byKind: [ScrollKind: [Duration?]]) -> Duration?
  }
  ```
- The probe (`ScrollLagProbe.run(drive: Bool) async`, main actor): finds the focused field as the app does (system-wide focused element, `EditableResolver.field(for:)`); skips secure fields; on every global `scrollWheel` event classifies it (`momentumPhase` set → momentum, else `hasPreciseScrollingDeltas` → trackpad, else wheel) and samples the bounds of the one-unit range at the caret (the unit before it at the end of the text), with the reader `SystemTextAccess.bounds` uses, every 10 ms on `AXQueue` until the trace settles or gives up. Sampling runs only inside a gesture. Each finished gesture logs one `PlatformLog.probe` line: bundle id, kind, lag in ms or "unsettled". On quit (after 10 minutes, or when a drive ends) it writes `~/Library/Application Support/com.michaelrigart.skald/probe/scroll-lag.json`: per bundle id and kind the lags in ms (null for unsettled) and the app's ceiling in ms or null.
- `--drive`: for each kind in turn, 20 gestures alternating down and up, each started only when `CGEventSource.secondsSinceLastEventType(.hidSystemState, …)` for any input is 8 s or more (it waits otherwise), with the pointer warped to the centre of the field's frame first and put back when the drive ends. Wheel: 5 line events of ±3, 20 ms apart. Trackpad: 12 pixel events of ±10 with scroll phases began, changed, ended, 16 ms apart. Momentum: a trackpad gesture, then 20 pixel events with momentum phases begin, continue, end and deltas falling from 10 to 1. The next gesture starts when the trace has settled or given up.

- [ ] **Step 1: Write the failing tests** in `ScrollLagTraceTests`:

```swift
private let a = CGRect(x: 10, y: 100, width: 30, height: 14), b = a.offsetBy(dx: 0, dy: -40)

@Test func theLagRunsFromTheLastScrollToTheLastChange() {
    var trace = ScrollLagTrace()
    trace.scrolled(.trackpad, at: .milliseconds(0))
    trace.sampled(a, at: .milliseconds(10))
    trace.scrolled(.momentum, at: .milliseconds(100))
    trace.sampled(a, at: .milliseconds(110))
    trace.sampled(b, at: .milliseconds(180))
    trace.sampled(b, at: .milliseconds(190))
    #expect(trace.kind == .momentum)
    #expect(trace.lag == .milliseconds(80))
    #expect(!trace.isSettled(at: .milliseconds(1179)))
    #expect(trace.isSettled(at: .milliseconds(1180)))
}

@Test func boundsThatNeverChangeAfterTheLastScrollLagZero() {
    var trace = ScrollLagTrace()
    trace.sampled(a, at: .milliseconds(0))
    trace.scrolled(.wheel, at: .milliseconds(50))
    trace.sampled(a, at: .milliseconds(60))
    #expect(trace.lag == .zero)
}

@Test func aTraceStillChangingFiveSecondsAfterTheLastScrollGivesUp() {
    var trace = ScrollLagTrace()
    trace.scrolled(.wheel, at: .zero)
    #expect(!trace.gaveUp(at: .milliseconds(4999)))
    #expect(trace.gaveUp(at: .seconds(5)))
    #expect(ScrollLagTrace().lag == nil)
}

@Test func theCeilingIsTheLargestLagRoundedUpAndNeedsTwentySettledGestures() {
    let twenty = Array(repeating: Duration.milliseconds(40), count: 19) + [.milliseconds(101)]
    #expect(ScrollLagSummary.ceiling(twenty) == .milliseconds(150))
    #expect(ScrollLagSummary.ceiling(Array(repeating: .zero, count: 20)) == .milliseconds(50))
    #expect(ScrollLagSummary.ceiling(Array(twenty.dropLast())) == nil)
    #expect(ScrollLagSummary.ceiling(twenty.dropLast() + [nil]) == nil)
    #expect(ScrollLagSummary.ceiling(byKind: [.wheel: twenty, .trackpad: twenty, .momentum: Array(repeating: .milliseconds(200), count: 20)]) == .milliseconds(200))
    #expect(ScrollLagSummary.ceiling(byKind: [.wheel: twenty, .trackpad: twenty]) == nil)
}
```

  and in `LaunchModeTests`: `--probe-scroll` from `/Applications` resolves to `.scrollProbe`, from elsewhere to `.wrongPlace`, and a Release build never sees it (the argument is read under `#if DEBUG`, as `--probe` is).

- [ ] **Step 2: Run** the Platform suite filtered to `ScrollLagTraceTests`; expected: FAIL, the types don't exist.
- [ ] **Step 3: Implement** the trace and summary, then the probe and the launch argument as the Interfaces say. The probe is `#if DEBUG`; `scripts/verify-app` must still find no probe in a Release build.
- [ ] **Step 4: Run** the Platform suite and the App suite; expected: PASS. Build Release and run `scripts/verify-app build/dd.noindex/Build/Products/Release/Skald.app`; expected: it passes.
- [ ] **Step 5: Commit** "Add a probe mode that measures how long an app's bounds lag behind a scroll".

**Measurement (controller, live, after the commit; not an implementer's step).** Build Debug, back up `/Applications/Skald.app` to `build/installed-backup/Skald.app`, install the Debug build. Make `build/scroll-probe/sample.txt` (the `Eval/seed.jsonl` texts repeated to 300 lines) and `build/scroll-probe/sample.html` (a page with one `<textarea autofocus rows="12">` holding the same text, itself taller than the window). For TextEdit and then Zen: open the sample, wait for focus, `open /Applications/Skald.app --args --probe-scroll --drive`, wait for it to quit, copy `scroll-lag.json` to `.superpowers/upgrade-evidence/scroll-lag-<app>.json`. Close the documents without saving, restore Michael's build. Notes needs a note in Michael's own data, so it is his step (see "Owed"). The ceilings measured go into Task 9's table; an app that could not be measured stays out of it. If `open` or the Accessibility grant is refused, skip the measurement, leave the table empty and report it as owed.

---

### Task 2: Categories and kinds

**Per-task review** (Tasks 3, 4, 6, 7 and 8 use it).

**Depends on:** none

**Files:**
- Create: `Packages/SkaldCore/Sources/SkaldCore/Issues/IssueKind.swift`, `Packages/SkaldCore/Sources/SkaldCore/Issues/IssueClassifier.swift`
- Modify: `Packages/SkaldCore/Sources/SkaldCoreTestSupport/OutcomeTable.swift` (every row gains its kind)
- Test: `Packages/SkaldCore/Tests/SkaldCoreTests/IssueClassifierTests.swift`, `Packages/SkaldPlatform27/Tests/SkaldPlatform27Tests/GuardOutcomeSystemTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum IssueCategory: String, Codable, CaseIterable, Sendable {
      case spelling, punctuation, grammar
      public var title: String            // "Spelling", "Punctuation", "Grammar"
  }
  public enum IssueKind: String, Codable, CaseIterable, Sendable {
      case spelling, capital, accent, punctuation, grammar, repeatedWord, verbForm
      public var category: IssueCategory
      public var title: String            // the table in "Values"
      public var isHideable: Bool
      /// "Grammar · Verb form"; just "Grammar" for a kind that is its category.
      public var headline: String
  }
  public enum IssueClassifier {
      /// `misspelled` holds the lowercased words of `edit.original` the paragraph's dictionary rejects.
      public static func kind(of edit: Edit, in paragraph: String, language: Language, source: IssueSource, misspelled: Set<String>) -> IssueKind
  }
  Row.kind: IssueKind   // a required `kind:` argument on both initialisers, after `expected`
  ```

- [ ] **Step 1: Write the failing tests** in `IssueClassifierTests`. A helper `kind(_ text: String, _ revised: String, _ language: Language = .en, source: IssueSource = .model, misspelled: Set<String> = [])` classifies the first edit of `TextDiff.edits(from:to:)`.

```swift
@Test func kindsHaveTheirCategoryTitleAndHeadline() {
    #expect(IssueKind.allCases.map(\.category) == [.spelling, .spelling, .spelling, .punctuation, .grammar, .grammar, .grammar])
    #expect(IssueKind.allCases.map(\.title) == ["Spelling", "Capital letter", "Accent", "Punctuation", "Grammar", "Repeated word", "Verb form"])
    #expect(IssueKind.allCases.filter(\.isHideable) == [.capital, .accent, .punctuation, .repeatedWord, .verbForm])
    #expect(IssueKind.verbForm.headline == "Grammar · Verb form")
    #expect(IssueKind.accent.headline == "Spelling · Accent")
    #expect(IssueKind.grammar.headline == "Grammar" && IssueKind.spelling.headline == "Spelling" && IssueKind.punctuation.headline == "Punctuation")
}

@Test func anEditIsClassifiedByWhatItChanges() {
    #expect(kind("We shipped it. The logs look fine", "We shipped it. The logs look fine.") == .punctuation)
    #expect(kind("Thanks , all good.", "Thanks, all good.") == .punctuation)
    #expect(kind("We meet on friday.", "We meet on Friday.") == .capital)
    #expect(kind("Cette operation est lente.", "Cette opération est lente.", .fr) == .accent)
    #expect(kind("cette Operation est lente.", "cette opération est lente.", .fr) == .accent)
    #expect(kind("I saw teh logs.", "I saw the logs.", source: .spelling) == .spelling)
    #expect(kind("I saw teh logs.", "I saw the logs.", misspelled: ["teh"]) == .spelling)
    #expect(kind("See you you tomorrow.", "See you tomorrow.") == .repeatedWord)
    #expect(kind("Het word morgen uitgerold.", "Het wordt morgen uitgerold.", .nl) == .verbForm)
    #expect(kind("Het is gebeurt.", "Het is gebeurd.", .nl) == .verbForm)
    #expect(kind("It word fine.", "It wordt fine.") == .grammar)                 // English: no d/t rule
    #expect(kind("Tout les serveurs sont à jour", "Tous les serveurs sont à jour", .fr) == .grammar)
    #expect(kind("I has it.", "I have it.") == .grammar)
    #expect(kind("See you soon tomorrow.", "See you tomorrow.") == .grammar)     // a deleted word that isn't repeated
    #expect(kind("Hij at het.", "Hij ad het.", .nl) == .grammar)                 // one letter left after the cut
}
```

  Then one parameterised test over `outcomeTable`, `everyRowOfTheOutcomeTableHasItsKind`: the row's first edit classified with the suite's existing facts for that row (the way `EditGuardTests` obtains them) equals `row.kind`. Fill every row's `kind:` by the "Values" rules, reading the row, not by running the classifier. `GuardOutcomeSystemTests` gains the same assertion with `SystemWordOracle`'s `misspelled`.

- [ ] **Step 2: Run** the Core suite filtered to `IssueClassifierTests`; expected: FAIL, the types don't exist.
- [ ] **Step 3: Implement** `IssueKind` and `IssueClassifier.kind` by the seven rules, in their order. Words come from `Tokenizer`, as in `EditGuard.words(in:)`, kept in their case; diacritics fold with `.diacriticInsensitive`; the neighbour of a deleted word is the nearest word token on either side of `edit.tokenSpan`.
- [ ] **Step 4: Run** the Core suite and the Platform suite; expected: PASS. A row whose kind the real dictionary and the fake disagree on is reported, not special-cased.
- [ ] **Step 5: Commit** "Classify every edit into a category and a kind".

---

### Task 3: Issues carry their kind and alternatives, and the snapshot says a field is checked

**Per-task review** (Tasks 4, 6, 7, 8 and 10 use it).

**Depends on:** Task 2 (`IssueKind`, `IssueClassifier`)

**Files:**
- Modify: `Packages/SkaldCore/Sources/SkaldCore/Issues/Issue.swift`, `Issues/IssueTracker.swift`, `Platform/SpellingChecking.swift`, `Pipeline/CheckPipeline.swift` (`IssueSnapshot`, `spell`, the model path's `anchored`, `accept`, `publish`)
- Modify: `Packages/SkaldPlatform27/Sources/SkaldPlatform27/Language/SpellingChecker.swift`, `Eval/EvalRunner.swift:240` (`.map(\.edit)`)
- Test: `Packages/SkaldCore/Tests/SkaldCoreTests/CheckPipelineTests.swift`, `IssueTrackerTests.swift`, `Support/FakeSpelling.swift`, `Packages/SkaldPlatform27/Tests/SkaldPlatform27Tests/SpellingTests.swift`; `SkaldTests/Support/IssueFixture.swift` (a `kind:` and `alternatives:` argument, defaulted)

**Interfaces:**
- Produces:
  ```swift
  public struct SpellingFlag: Equatable, Sendable {
      public static let maxAlternatives = 2
      public let edit: Edit            // the first guess, as today (an empty replacement when there is none)
      public let alternatives: [Edit]  // further guesses over the same `range`, at most `maxAlternatives`
      public init(edit: Edit, alternatives: [Edit] = [])
  }
  protocol SpellingChecking { func flags(in p: Paragraph, language: Language, neverTouch: Set<String>) async -> [SpellingFlag] }

  Issue.kind: IssueKind            // init argument `kind: IssueKind? = nil`: nil means .spelling for a spelling issue, .grammar for a model one
  Issue.alternatives: [Edit]       // init argument `alternatives: [Edit] = []`; relative to `chunk`, like `edit`
  IssueSnapshot.checked: Bool      // init(field:issues:checked: Bool = false)
  IssueTracker.hasResults(in field: FieldID) -> Bool
  CheckPipeline.accept(_ id: UUID, alternative: Int? = nil) async -> ReplaceOutcome
  ```
- `Issue` stays `Hashable`; `IssueTracker.revalidate` carries `kind` and `alternatives` over; the tracker's ignore and twin rules keep comparing `edit` only.
- The pipeline: a spelling issue's kind is `IssueClassifier.kind(…, source: .spelling, misspelled: [])`. A model issue's kind uses `misspelled` from one `oracle.facts(for:language:)` call over the kept edits' words, made before the checks that follow the last `await` (`isCurrent`, the route) so they still guard the publish; no call when nothing was kept. Alternatives: the guesses of a kept flag that `editGuard.resolve(…, source: .spelling, confirmer: nil)` also keeps, in order.
- `hasResults(in:)`: true once `setSpelling` or `setModel` has run for a key of that field and until that key is cleared, dropped by `revalidate`, or everything is cleared; false while the field is suspended. `publish` sets `checked = !isPaused && hasResults(in: currentField)`.
- `SpellingChecker`: Dutch and French take the checker's guesses after the first; English takes the American guesses the British dictionary accepts, without the first guess chosen. A guess is kept only when it differs from the first and its `TextDiff` edit has the first guess's `range`.

- [ ] **Step 1: Write the failing tests.** `FakeSpelling` takes `[String: [String]]` (guesses per misspelling; the existing `[String: String]` initialiser stays as a convenience). In `CheckPipelineTests`, with the suite's rig:

```swift
@Test func aSpellingIssueCarriesItsKindAndUpToTwoMoreGuesses() async {
    // rig spelling: ["teh": ["the", "ten", "tea", "tech"]], field text "teh end"
    let issue = try #require(await rig.publishedIssues().first)
    #expect(issue.kind == .spelling)
    #expect(issue.edit.replacement == "the")
    #expect(issue.alternatives.map(\.replacement) == ["ten", "tea"])
}

@Test func aModelIssueIsClassified() async {
    // engine answers "Het wordt morgen uitgerold." for "Het word morgen uitgerold." (nl, model checks on)
    #expect(await rig.publishedIssues().map(\.kind) == [.verbForm])
}

@Test func aNeverTouchGuessIsNotOfferedAsAnAlternative() async  // neverTouch ["ten"] → alternatives == ["tea"]

@Test func acceptingAnAlternativeWritesItsText() async {
    #expect(await rig.pipeline.accept(issue.id, alternative: 1) == .replaced)
    #expect(await rig.access.replacements.last?.text == "tea")
}

@Test func anUnknownAlternativeIsRefused() async {
    #expect(await rig.pipeline.accept(issue.id, alternative: 2) == .failed)
    #expect(await rig.access.replacements.isEmpty)
    #expect(await rig.pipeline.lastPublished.issues.map(\.id) == [issue.id])   // the issue is still there
}

@Test func theSnapshotSaysCheckedOnceAResultIsIn() async {
    // focus a field holding "all fine here": before spelling answers → checked == false, issues == []
    // after it answers → checked == true, issues == []; after setPaused(true) → checked == false
}
```

  In `IssueTrackerTests`: `hasResults(in:)` is false for a fresh tracker, true after `setSpelling([], for: key)`, false after `clear(key)`, false while suspended, and a revalidated issue keeps `kind` and `alternatives`. In `SpellingTests` (tagged `requiresSystem`): a misspelling with several guesses yields alternatives that all differ from `edit.replacement`, share `edit.range`, and number at most 2.

- [ ] **Step 2: Run** the Core suite; expected: FAIL to compile on the new members.
- [ ] **Step 3: Implement** as the Interfaces say. `accept` with an alternative writes that edit's `writeRange` and `writeText` through the same `access.replace(…, expected: issue.expected, …)`; an index out of range returns `.failed` before any write and removes nothing.
- [ ] **Step 4: Run** the Core, Platform and App suites; expected: PASS, with every existing assertion as it was.
- [ ] **Step 5: Commit** "Publish each issue's kind and the spell checker's other guesses, and whether the field was checked".

---

### Task 4: Hidden kinds, the review shortcut and the two pauses in the settings

**Per-task review** (the settings file's format; Tasks 8, 10 and 11 use it).

**Depends on:** Task 3 (`Issue.kind`, the pipeline's `publish`)

**Files:**
- Modify: `Packages/SkaldCore/Sources/SkaldCore/Settings/Settings.swift`, `Pipeline/CheckPipeline.swift` (`publish`), `Skald/SettingsModel.swift`, `Skald/StatusItemController.swift` and `Skald/CompositionRoot.swift` and `Skald/Settings/GeneralPane.swift` (only the renamed pause call)
- Test: `Packages/SkaldCore/Tests/SkaldCoreTests/SettingsStoreTests.swift`, `CheckPipelineTests.swift`, `SkaldTests/SettingsModelTests.swift`

**Interfaces:**
- Produces:
  ```swift
  Settings.hiddenKinds: Set<IssueKind>     // default []; stored under "hiddenKinds" as a sorted array of raw values
  Settings.reviewHotkey: Hotkey            // default Hotkey.review
  Hotkey.review = Hotkey(keyCode: 15, modifiers: controlModifier | optionModifier)   // ⌃⌥R
  Settings.hide(_ kind: IssueKind)         // mutating; ignores a kind that isn't hideable
  Settings.show(_ kind: IssueKind)         // mutating
  SettingsModel.pause(for interval: TimeInterval, now: Date = .now)   // replaces pauseForAnHour(now:)
  SettingsModel.hide(_ kind: IssueKind), SettingsModel.show(_ kind: IssueKind)
  ```
- `publish` leaves out issues whose kind is in `settings.hiddenKinds`; `checked` is unaffected. `update(settings:)` already republishes; a change to `hiddenKinds` or `reviewHotkey` alone triggers no recheck.

- [ ] **Step 1: Write the failing tests.**

```swift
// SettingsStoreTests
@Test func hiddenKindsAndTheReviewShortcutRoundTrip() throws {
    var settings = Settings()
    settings.hide(.verbForm); settings.hide(.punctuation); settings.hide(.grammar); settings.hide(.spelling)
    settings.reviewHotkey = Hotkey(keyCode: 45, modifiers: 0x0100)
    #expect(settings.hiddenKinds == [.verbForm, .punctuation])
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
    #expect(json?["hiddenKinds"] as? [String] == ["punctuation", "verbForm"])
    #expect(json?["version"] as? Int == 2)
    #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)) == settings)
}

@Test func aStage1FileReadsWithNothingHiddenAndTheDefaultShortcut() throws   // {"version":2,"claudeTyping":true} → hiddenKinds == [], reviewHotkey == .review, claudeTyping == true

@Test func anUnknownOrUnhideableStoredKindIsDropped() throws   // "hiddenKinds":["verbForm","tone","grammar"] → [.verbForm]

// CheckPipelineTests
@Test func hidingAKindRepublishesWithoutIt() async {
    // published: one .verbForm issue and one .spelling issue, checked == true
    var settings = rig.settings; settings.hide(.verbForm)
    await rig.pipeline.update(settings: settings)
    #expect(await rig.pipeline.lastPublished.issues.map(\.kind) == [.spelling])
    #expect(await rig.pipeline.lastPublished.checked)
    #expect(await rig.engine.requests.count == requestsBefore)          // no recheck
    settings.show(.verbForm)
    await rig.pipeline.update(settings: settings)
    #expect(await rig.pipeline.lastPublished.issues.map(\.kind) == [.verbForm, .spelling])   // in text order
}

// SettingsModelTests
@Test func pausingSetsTheEndFromTheInterval() {
    model.pause(for: 30 * 60, now: Date(timeIntervalSince1970: 1000))
    #expect(model.settings.pausedUntil == Date(timeIntervalSince1970: 2800))
}
```

- [ ] **Step 2: Run** the Core suite; expected: FAIL to compile.
- [ ] **Step 3: Implement.** Decode `hiddenKinds` leniently (strings; unknown or unhideable names dropped); `reviewHotkey` with `decodeIfPresent`. Callers of `pauseForAnHour` pass `60 * 60`.
- [ ] **Step 4: Run** the Core and App suites; expected: PASS.
- [ ] **Step 5: Commit** "Store hidden kinds and the review shortcut, and pause for any interval".

---

### Task 5: The scroll rule

**Per-task review** (Task 9 uses it).

**Depends on:** none

**Files:**
- Create: `Packages/SkaldCore/Sources/SkaldCore/Overlay/ScrollSettle.swift`
- Test: `Packages/SkaldCore/Tests/SkaldCoreTests/ScrollSettleTests.swift`

**Interfaces:**
- Produces:
  ```swift
  /// When underlines may show after a scroll. Times are instants on the caller's clock, as durations from its start.
  public struct ScrollSettle<Reading: Equatable & Sendable>: Sendable {
      public enum Action: Equatable, Sendable { case hide, read(after: Duration), show }
      public static var confirmingReads: Int { 3 }
      public static var maxReads: Int { 20 }
      public init(ceiling: Duration?)                        // nil: an unmeasured app
      public private(set) var isHidden: Bool                  // false at first
      public mutating func scrolled(at now: Duration) -> [Action]
      public mutating func read(_ reading: Reading, at now: Duration) -> [Action]
      /// A text or caret change drew fresh underlines: showing again, nothing pending.
      public mutating func redrawn()
  }
  ```
- `scrolled`: `[.hide, .read(after: ceiling)]` when measured, `[.hide]` when not; it forgets earlier reads and restarts the count. `read` while hidden: `[.show, .read(after: ceiling)]` when it equals the read before it and `now − lastScroll ≥ 2 × ceiling`; otherwise it is remembered and `[.read(after: ceiling)]`, or `[]` once `maxReads` reads were taken since the last scroll. `read` while confirming: equal to the shown reading → `[.read(after: ceiling)]` until `confirmingReads` have agreed, then `[]`; different → `[.hide, .read(after: ceiling)]`, with `now` as the new last scroll and this reading remembered. Any other `read` → `[]`.

- [ ] **Step 1: Write the failing tests.** `c = Duration.milliseconds(100)`, readings are strings.

```swift
@Test func aScrollHidesAndAsksForARead() {
    var settle = ScrollSettle<String>(ceiling: c)
    #expect(settle.scrolled(at: .zero) == [.hide, .read(after: c)])
    #expect(settle.isHidden)
}

@Test func equalReadsInsideTheSpanDoNotShow() {
    var settle = ScrollSettle<String>(ceiling: c)
    _ = settle.scrolled(at: .zero)
    #expect(settle.read("a", at: .milliseconds(100)) == [.read(after: c)])
    #expect(settle.read("a", at: .milliseconds(199)) == [.read(after: c)])
    #expect(settle.isHidden)
}

@Test func equalReadsAcrossTheSpanShow() {
    var settle = ScrollSettle<String>(ceiling: c)
    _ = settle.scrolled(at: .zero)
    _ = settle.read("a", at: .milliseconds(100))
    #expect(settle.read("a", at: .milliseconds(200)) == [.show, .read(after: c)])
    #expect(!settle.isHidden)
}

@Test func theSpanCountsFromTheLastScrollEvent() {
    var settle = ScrollSettle<String>(ceiling: c)
    _ = settle.scrolled(at: .zero)
    _ = settle.read("a", at: .milliseconds(100))
    _ = settle.scrolled(at: .milliseconds(150))
    #expect(settle.read("a", at: .milliseconds(250)) == [.read(after: c)])   // the read before the scroll is forgotten
    #expect(settle.read("a", at: .milliseconds(349)) == [.read(after: c)])
    #expect(settle.read("a", at: .milliseconds(350)) == [.show, .read(after: c)])
}

@Test func aDifferingReadAfterShowingHidesAgainAndStartsOver() {
    var settle = shown("a", at: .milliseconds(200))
    #expect(settle.read("a", at: .milliseconds(300)) == [.read(after: c)])
    #expect(settle.read("b", at: .milliseconds(400)) == [.hide, .read(after: c)])
    #expect(settle.read("b", at: .milliseconds(500)) == [.read(after: c)])
    #expect(settle.read("b", at: .milliseconds(600)) == [.show, .read(after: c)])
}

@Test func threeAgreeingReadsEndTheConfirming() {
    var settle = shown("a", at: .milliseconds(200))
    #expect(settle.read("a", at: .milliseconds(300)) == [.read(after: c)])
    #expect(settle.read("a", at: .milliseconds(400)) == [.read(after: c)])
    #expect(settle.read("a", at: .milliseconds(500)) == [])
    #expect(settle.read("b", at: .milliseconds(600)) == [])
    #expect(!settle.isHidden)
}

@Test func readsStopAfterTheBound() {
    var settle = ScrollSettle<Int>(ceiling: c)
    _ = settle.scrolled(at: .zero)
    for n in 1..<20 { #expect(settle.read(n, at: c * n) == [.read(after: c)]) }
    #expect(settle.read(20, at: c * 20) == [])
    #expect(settle.isHidden)
}

@Test func anUnmeasuredAppStaysHiddenUntilItIsRedrawn() {
    var settle = ScrollSettle<String>(ceiling: nil)
    #expect(settle.scrolled(at: .zero) == [.hide])
    #expect(settle.read("a", at: .seconds(10)) == [])
    #expect(settle.isHidden)
    settle.redrawn()
    #expect(!settle.isHidden)
}

@Test func aRedrawEndsAPendingSettle() {
    var settle = ScrollSettle<String>(ceiling: c)
    _ = settle.scrolled(at: .zero)
    settle.redrawn()
    #expect(settle.read("a", at: .milliseconds(100)) == [])
    #expect(!settle.isHidden)
}
```

- [ ] **Step 2: Run** the Core suite filtered to `ScrollSettleTests`; expected: FAIL.
- [ ] **Step 3: Implement** `ScrollSettle` as a small state enum (showing, hidden with the last read and a count, confirming with the shown reading and a count).
- [ ] **Step 4: Run** the Core suite; expected: PASS.
- [ ] **Step 5: Commit** "Decide when underlines may come back after a scroll".

---

### Task 6: Review mode's state machine

**Per-task review** (Task 10 uses it).

**Depends on:** Task 3 (`Issue.fieldRange`, `ReplaceOutcome`)

**Files:**
- Create: `Packages/SkaldCore/Sources/SkaldCore/Issues/ReviewMode.swift`
- Test: `Packages/SkaldCore/Tests/SkaldCoreTests/ReviewModeTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ReviewMode: Sendable {
      public enum Key: Sendable, CaseIterable { case next, previous, accept, dismiss, leave }
      public enum Phase: Equatable, Sendable { case closed, showing(UUID), applying(UUID) }
      public enum Effect: Equatable, Sendable {
          case show(UUID)       // open this issue's card
          case accept(UUID)     // start the write; report its outcome with `finished`
          case copy(UUID)       // no clean write here: copy the fix, the card stays
          case dismiss(UUID)
          case close            // free the keys and close a card that is only offering its choices
      }
      public static let ownEditGrace: Duration = .seconds(1)
      public init()
      public private(set) var phase: Phase
      /// The field offset the mode stands on: the shown issue's start.
      public private(set) var position: Int
      public var holdsKeys: Bool { phase != .closed }
      /// The shortcut: opens on the first issue (nothing when there is none), or leaves.
      public mutating func toggle(issues: [Issue]) -> [Effect]
      public mutating func key(_ key: Key, issues: [Issue], writes: Bool) -> [Effect]
      public mutating func finished(_ outcome: ReplaceOutcome, issues: [Issue], at now: Duration) -> [Effect]
      public mutating func issuesChanged(_ issues: [Issue]) -> [Effect]
      public mutating func edited(at now: Duration) -> [Effect]
      /// A focus change, a click elsewhere, a pause, the overlay stopping.
      public mutating func left() -> [Effect]
  }
  ```
- `issues` is always the focused field's published list. Rules are the "Values" rows "Review, which issue" and "Own edits". `issuesChanged` while showing an issue that is still listed returns `[]` and moves `position` to that issue's start; while applying it returns `[]`. `edited` returns `[.close]` while showing and past the grace, `[]` otherwise. Every method returns `[]` when closed, except `toggle`.

- [ ] **Step 1: Write the failing tests.** A helper `issues(at: [Int])` makes one issue per start offset in one field (ids `a`, `b`, `c` in order); `open(_:)` returns a mode toggled open on them.

```swift
@Test func theShortcutOpensOnTheFirstIssueAndLeavesWhenPressedAgain() {
    var mode = ReviewMode()
    #expect(mode.toggle(issues: []) == [] && !mode.holdsKeys)
    #expect(mode.toggle(issues: [a, b, c]) == [.show(a.id)])
    #expect(mode.phase == .showing(a.id) && mode.position == 4 && mode.holdsKeys)
    #expect(mode.toggle(issues: [a, b, c]) == [.close])
    #expect(mode.phase == .closed && !mode.holdsKeys)
}

@Test func nextAndPreviousPickTheNearestIssueFromThePosition() {
    var mode = open([a, b, c])                                       // starts 4, 20, 31
    #expect(mode.key(.next, issues: [a, b, c], writes: true) == [.show(b.id)])
    #expect(mode.key(.next, issues: [a, c], writes: true) == [.show(c.id)])        // b went meanwhile
    #expect(mode.key(.next, issues: [a, c], writes: true) == [])                    // nothing after 31
    #expect(mode.key(.previous, issues: [a, b, c], writes: true) == [.show(b.id)])
    #expect(mode.key(.previous, issues: [a, b, c], writes: true) == [.show(a.id)])
    #expect(mode.key(.previous, issues: [a, b, c], writes: true) == [])
}

@Test func anAcceptKeepsTheModeOpenAndMovesOnWhenTheWriteIsConfirmed() {
    var mode = open([a, b, c])
    #expect(mode.key(.accept, issues: [a, b, c], writes: true) == [.accept(a.id)])
    #expect(mode.phase == .applying(a.id))
    for key in [ReviewMode.Key.next, .previous, .accept, .dismiss] { #expect(mode.key(key, issues: [b, c], writes: true) == []) }
    #expect(mode.holdsKeys)
    #expect(mode.issuesChanged([b, c]) == [])
    #expect(mode.finished(.replaced, issues: [b, c], at: .seconds(10)) == [.show(b.id)])
    #expect(mode.phase == .showing(b.id))
}

@Test func theLastAcceptEndsTheModeAndAnEarlierIssueIsShownWhenNoneFollows() {
    var last = open([a])
    _ = last.key(.accept, issues: [a], writes: true)
    #expect(last.finished(.replaced, issues: [], at: .zero) == [.close])
    var back = open([a, b])
    _ = back.key(.next, issues: [a, b], writes: true)
    _ = back.key(.accept, issues: [a, b], writes: true)
    #expect(back.finished(.replaced, issues: [a], at: .zero) == [.show(a.id)])
}

@Test(arguments: [ReplaceOutcome.failed, .refusedChanged, .refusedOtherField, .unsupported, .clipboardBusy, .unconfirmed])
func aWriteThatIsNotConfirmedEndsTheMode(_ outcome: ReplaceOutcome) {
    var mode = open([a, b])
    _ = mode.key(.accept, issues: [a, b], writes: true)
    #expect(mode.finished(outcome, issues: [b], at: .zero) == [.close])
    #expect(!mode.holdsKeys)
}

@Test func escLeavesEvenWhileAWriteIsApplied() {
    var mode = open([a])
    _ = mode.key(.accept, issues: [a], writes: true)
    #expect(mode.key(.leave, issues: [], writes: true) == [.close])
    #expect(mode.finished(.replaced, issues: [], at: .zero) == [])
}

@Test func withoutACleanWriteAcceptCopiesAndStays() {
    var mode = open([a, b])
    #expect(mode.key(.accept, issues: [a, b], writes: false) == [.copy(a.id)])
    #expect(mode.phase == .showing(a.id))
}

@Test func dismissMovesOn() {
    var mode = open([a, b])
    #expect(mode.key(.dismiss, issues: [a, b], writes: true) == [.dismiss(a.id), .show(b.id)])
    #expect(mode.key(.dismiss, issues: [b], writes: true) == [.dismiss(b.id), .close])
}

@Test func theShownIssueVanishingMovesToTheNearest() {
    var mode = open([a, b, c])
    _ = mode.key(.next, issues: [a, b, c], writes: true)             // on b, position 20
    #expect(mode.issuesChanged([a, c]) == [.show(c.id)])
    #expect(mode.issuesChanged([a]) == [.show(a.id)])
    #expect(mode.issuesChanged([]) == [.close])
}

@Test func theShownIssueMovingMovesThePositionWithIt() {
    var mode = open([a, b])
    #expect(mode.issuesChanged([a.moved(to: 9), b]) == [])
    #expect(mode.position == 9)
}

@Test func anEditThatIsNotSkaldsOwnLeaves() {
    var mode = open([a, b])
    _ = mode.key(.accept, issues: [a, b], writes: true)
    #expect(mode.edited(at: .seconds(9)) == [])                       // the write itself
    _ = mode.finished(.replaced, issues: [b], at: .seconds(10))
    #expect(mode.edited(at: .seconds(11)) == [])                      // within the grace
    #expect(mode.edited(at: .milliseconds(11001)) == [.close])
}

@Test func everyWayOutClosesTheMode() {
    for leave: (inout ReviewMode) -> [ReviewMode.Effect] in [
        { $0.left() }, { $0.toggle(issues: [a]) }, { $0.key(.leave, issues: [a], writes: true) },
        { $0.issuesChanged([]) }, { $0.edited(at: .seconds(100)) },
    ] {
        var mode = open([a])
        #expect(leave(&mode) == [.close])
        #expect(mode.phase == .closed && !mode.holdsKeys)
        #expect(ReviewMode.Key.allCases.allSatisfy { mode.key($0, issues: [a], writes: true) == [] })
    }
}
```

- [ ] **Step 2: Run** the Core suite filtered to `ReviewModeTests`; expected: FAIL.
- [ ] **Step 3: Implement** `ReviewMode`.
- [ ] **Step 4: Run** the Core suite; expected: PASS.
- [ ] **Step 5: Commit** "Add review mode's state machine".

---

### Task 7: Colours by category, the badge in every checked field, and the legend

**Per-task review** (Tasks 8, 9 and 11 use it).

**Depends on:** Task 3 (`Issue.kind`, `IssueSnapshot.checked`)

**Files:**
- Create: `Skald/Overlay/CategoryPalette.swift`, `Skald/Overlay/LegendView.swift`
- Modify: `Skald/Overlay/UnderlineView.swift`, `Skald/Overlay/BadgeView.swift`, `Skald/Overlay/OverlayController.swift` (`received`, `drawMarks`, `badgeClicked`)
- Test: `SkaldTests/CategoryPaletteTests.swift`, `SkaldTests/BadgeTests.swift`, `SkaldTests/OverlayGeometryTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum CategoryPalette {
      struct RGB: Equatable { let red, green, blue: Double }      // sRGB, 0...1
      static func rgb(_ category: IssueCategory, dark: Bool) -> RGB   // the "Values" table
      static func color(_ category: IssueCategory) -> NSColor        // dynamic: follows the appearance
      static func isDotted(_ category: IssueCategory) -> Bool        // punctuation only
  }
  UnderlineView.Mark(rect: CGRect, category: IssueCategory)          // replaces `source`
  struct LegendView: View                                            // three rows: a 2 pt sample line in the colour (dotted for Punctuation) and the title
  enum BadgeContent: Equatable { case count(Int), tick }
  BadgePanel.show(_ content: BadgeContent, label: String, at frame: CGRect)
  static func OverlayGeometry.badgeLabel(_ issues: [Issue]) -> String
  ```
- `badgeLabel`: `"No suggestions"`; `"1 suggestion: 1 spelling"`; `"3 suggestions: 2 spelling, 1 grammar"` (categories in `IssueCategory.allCases` order, zero counts left out, lowercase titles).
- The controller: `drawMarks` no longer returns early on an empty list. With a field, the field's frame and `.fieldFrame`: the badge shows `.count(n)` for n > 0, `.tick` for zero issues when `snapshot.checked`, and hides otherwise. It shows beside underlines too. Underlines are drawn model issues first, as today, each in its category's colour; an underline in an inactive appearance still follows the system appearance (`NSApp.effectiveAppearance`). A click on the tick does nothing.

- [ ] **Step 1: Write the failing tests.**

```swift
// CategoryPaletteTests
@Test func theColoursAreTheOnesDecided() {
    #expect(CategoryPalette.rgb(.spelling, dark: false) == .init(hex: 0xD55E00))
    #expect(CategoryPalette.rgb(.grammar, dark: false) == .init(hex: 0x0072B2))
    #expect(CategoryPalette.rgb(.punctuation, dark: false) == .init(hex: 0x4B0082))
    #expect(CategoryPalette.rgb(.spelling, dark: true) == .init(hex: 0xFF8A4C))
    #expect(CategoryPalette.rgb(.grammar, dark: true) == .init(hex: 0x56B4E9))
    #expect(CategoryPalette.rgb(.punctuation, dark: true) == .init(hex: 0xFFE66D))
    #expect(IssueCategory.allCases.filter(CategoryPalette.isDotted) == [.punctuation])
}

/// Machado, Oliveira and Fernandes (2009), severity 1.0, applied in linear RGB; the distance is Euclidean in sRGB.
@Test(arguments: [false, true]) func everyPairStaysApartUnderEachDeficiency(dark: Bool) {
    for matrix in [Simulation.none, .protanopia, .deuteranopia, .tritanopia] {
        for (a, b) in [(IssueCategory.spelling, .grammar), (.spelling, .punctuation), (.grammar, .punctuation)] {
            #expect(matrix.distance(CategoryPalette.rgb(a, dark: dark), CategoryPalette.rgb(b, dark: dark)) >= 0.3)
        }
    }
}

@Test func everyColourReadsOnItsBackground() {     // WCAG contrast ratio
    for category in IssueCategory.allCases {
        #expect(contrast(CategoryPalette.rgb(category, dark: false), .init(hex: 0xFFFFFF)) >= 3.0)
        #expect(contrast(CategoryPalette.rgb(category, dark: true), .init(hex: 0x1E1E1E)) >= 4.5)
    }
}
```

  The test file holds the three matrices (protanopia `[[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]]`, deuteranopia `[[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]]`, tritanopia `[[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.303900]]`), the sRGB transfer functions and the contrast formula.

```swift
// OverlayGeometryTests
@Test func theBadgeLabelCountsByCategory() {
    #expect(OverlayGeometry.badgeLabel([]) == "No suggestions")
    #expect(OverlayGeometry.badgeLabel([spelling]) == "1 suggestion: 1 spelling")
    #expect(OverlayGeometry.badgeLabel([grammar, spelling, accent, comma]) == "4 suggestions: 2 spelling, 1 punctuation, 1 grammar")
}

// BadgeTests
@Test func theBadgeShowsACountOrATickAndSaysSo() {
    let view = BadgeView()
    view.show(.count(3), label: "3 suggestions: 3 spelling")
    #expect(view.accessibilityLabel() == "3 suggestions: 3 spelling" && view.content == .count(3))
    view.show(.tick, label: "No suggestions")
    #expect(view.accessibilityLabel() == "No suggestions" && view.content == .tick)
}
```

- [ ] **Step 2: Run** the App suite; expected: FAIL to compile.
- [ ] **Step 3: Implement.** `UnderlineView` fills a solid rounded rect, or for a dotted category 2 pt squares every 4 pt along the rect (at least one). The tick is an SF Symbol `checkmark` in a grey circle at 60 % opacity.
- [ ] **Step 4: Run** the App suite; expected: PASS.
- [ ] **Step 5: Commit** "Colour underlines by category and show the counter in every checked field".

---

### Task 8: The card

**Per-task review** (Task 10 uses it).

**Depends on:** Task 3 (`Issue.kind`, `alternatives`, `accept(_:alternative:)`), Task 4 (`SettingsModel.hide`), Task 7 (`CategoryPalette`)

**Files:**
- Modify: `Skald/Overlay/CardOutcome.swift` (`IssueCardModel`), `Skald/Overlay/IssueCard.swift` (`IssueCardView`), `Skald/Overlay/OverlayController.swift` (`card(_:)`, the actions)
- Test: `SkaldTests/CardOutcomeTests.swift`, `SkaldTests/CardPanelTests.swift`

**Interfaces:**
- Produces, on `IssueCardModel`:
  ```swift
  struct Actions {
      let accept: (UUID, _ alternative: Int?) async -> ReplaceOutcome
      let dismiss: (UUID) -> Void                 // was `ignore`
      let addToDictionary: (UUID) -> Void         // was `neverFlag`; still writes the never-touch list
      let hide: (IssueKind) -> Void
  }
  let kind: IssueKind
  var headline: String { kind.headline }
  let alternatives: [String]                      // the other guesses' replacements, in order
  var hideTitle: String?                          // #"Hide "Verb form" suggestions"# while ready and the kind is hideable, else nil
  var dictionaryTitle: String?                    // #"Add "word" to dictionary"# while ready with an original word, else nil
  var label: String                               // the "Labels" row, from the category and the content
  var reviewing: Bool                             // set by the controller; the card then shows its key line
  static let reviewKeys = "↩ accept   ⌫ dismiss   ← → move   esc leave"
  func accept(alternative: Int? = nil) async
  func dismiss()
  func addToDictionary()
  func hide()                                     // calls actions.hide(kind), then closes
  ```
- The view, top to bottom: the headline with a dot in the category's colour, and "Claude" at the right when Claude found it; the change in context (as today); one button per alternative (its text; a click accepts it); `Accept` (prominent) or, without a clean write, `Copy fix`; `Dismiss`; a `⋯` menu (`Menu` with `.menuIndicator(.hidden)`) holding the hide item when `hideTitle` is set, the dictionary item when `dictionaryTitle` is set, and "Copy fix" when the fix has text. In review, `reviewKeys` as a caption under the buttons while the card is ready. The working, finished and notice phases stay as they are.
- Accessibility: every control's label ends with the card's `label`: "Accept: Grammar: word, change to wordt", "Dismiss: …", "More: …", and for an alternative "Use ‹guess›: …". The headline and change are one element labelled `label`. The list is a list of those.
- The controller: `hide` goes to `settings.hide(kind)`; the pipeline's republish removes every issue of that kind, which closes their cards through `retain`.

- [ ] **Step 1: Write the failing tests** in `CardOutcomeTests` (the suite's `issue(in:revised:…)` fixture, with `kind:` and `alternatives:`):

```swift
@Test func theCardSaysItsKindAndOffersToHideOnlyAHideableOne() {
    let verb = card(issue(in: "Het word morgen.", revised: "Het wordt morgen.", kind: .verbForm))
    #expect(verb.headline == "Grammar · Verb form")
    #expect(verb.hideTitle == #"Hide "Verb form" suggestions"#)
    #expect(card(issue(in: "I has it.", revised: "I have it.", kind: .grammar)).hideTitle == nil)
    #expect(card(issue(in: "teh end", revised: "the end", source: .spelling)).hideTitle == nil)
    #expect(card(issue(in: "Fine", revised: "Fine.", kind: .punctuation)).hideTitle == #"Hide "Punctuation" suggestions"#)
}

@Test func theLabelNamesTheCategoryAndTheChange() {
    #expect(card(issue(in: "Het word morgen.", revised: "Het wordt morgen.", kind: .verbForm)).label == "Grammar: word, change to wordt")
    #expect(card(issue(in: "Fine", revised: "Fine.", kind: .punctuation)).label == "Punctuation: add .")
    #expect(card(issue(in: "See you you soon.", revised: "See you soon.", kind: .repeatedWord)).label == "Grammar: remove you")
}

@Test func hidingCallsTheActionWithTheKindAndCloses() {
    var hidden: [IssueKind] = []
    let card = card(issue(in: "Fine", revised: "Fine.", kind: .punctuation), hide: { hidden.append($0) })
    card.hide()
    #expect(hidden == [.punctuation] && card.phase == .closed)
}

@Test func anAlternativeIsAcceptedByItsIndex() async {
    var asked: [Int?] = []
    let card = card(spelling(guesses: ["the", "ten", "tea"]), accept: { _, index in asked.append(index); return .replaced })
    #expect(card.alternatives == ["ten", "tea"])
    await card.accept(alternative: 1)
    #expect(asked == [1] && card.phase == .closed)
}

@Test func theDictionaryItemNamesTheWordAndAnInsertionHasNone() {
    #expect(card(issue(in: "teh end", revised: "the end", source: .spelling)).dictionaryTitle == #"Add "teh" to dictionary"#)
    #expect(card(issue(in: "Fine", revised: "Fine.", kind: .punctuation)).dictionaryTitle == nil)
}
```

  Every existing test keeps its assertions under the new names (`ignore` → `dismiss`, `neverFlag` → `addToDictionary`, `neverFlagWord` → `dictionaryTitle`'s word).

- [ ] **Step 2: Run** the App suite; expected: FAIL to compile.
- [ ] **Step 3: Implement** the model changes, the view and the controller's actions.
- [ ] **Step 4: Run** the App suite; expected: PASS.
- [ ] **Step 5: Commit** "Give the card its kind, alternatives, Dismiss and a menu that hides a kind".

---

### Task 9: Hide on scroll, come back when the reads agree, and check a hover

**Depends on:** Task 1 (the measured ceilings), Task 5 (`ScrollSettle`), Task 7 (the controller's drawing)

**Files:**
- Create: `Skald/Overlay/ScrollLag.swift`
- Modify: `Skald/Overlay/OverlayController.swift` (`moved`, `drawMarks` split, `rested(on:)`), `Skald/Overlay/HoverTracker.swift`
- Test: `SkaldTests/ScrollLagTests.swift`, `SkaldTests/HoverTrackerTests.swift`

**Interfaces:**
- Consumes: `ScrollSettle<[CGRect]>` and its actions (Task 5).
- Produces:
  ```swift
  enum ScrollLag {
      /// Measured 2026-11 with `--probe-scroll` (spec, "Underlines and scrolling"). Only measured apps are here.
      static let ceilings: [String: Duration]
      static func ceiling(for bundleID: String) -> Duration?
  }
  /// False when the word is no longer where its underline was drawn: more than `moveTolerance` on either axis, or unreadable.
  static func HoverTracker.isStill(drawn: CGRect, read: CGRect?) -> Bool      // both in AppKit coordinates
  static let HoverTracker.moveTolerance: CGFloat = 2
  ```
- `ceilings` holds exactly the ceilings from Task 1's measurement files (`.superpowers/upgrade-evidence/scroll-lag-*.json`), by bundle id; the controller gives the implementer the values. With no measurement it is empty.
- The controller: `drawMarks` splits into a read (`layout() async -> Layout?`: the marks, targets and badge for the current snapshot) and a show. A scroll event cancels a pending settle read, feeds `settle.scrolled(at:)` and executes the actions: `.hide` hides the underlines and closes a hover card that is only offering its choices (the badge and its count stay); `.read(after:)` sleeps on the injected clock, takes a layout and feeds its marks' rects to `settle.read`; `.show` shows that layout. A snapshot, a text change, a caret move or a window move redraws as today and calls `settle.redrawn()`. The settle is made per focused field from `ScrollLag.ceiling(for: field.app)`. No read is ever scheduled except by these actions.
- A hover: `rested(on:)` reads the word's bounds again (`access.bounds([OverlayGeometry.underlineRange(for: issue)], in: field)`); if `isStill` and the pointer is still on that word, the card opens; otherwise `requestRedraw()` and no card.

- [ ] **Step 1: Write the failing tests.**

```swift
// HoverTrackerTests
@Test func aWordThatMovedOrCannotBeReadIsNotStill() {
    let drawn = CGRect(x: 100, y: 400, width: 40, height: 16)
    #expect(HoverTracker.isStill(drawn: drawn, read: drawn.offsetBy(dx: 2, dy: -2)))
    #expect(!HoverTracker.isStill(drawn: drawn, read: drawn.offsetBy(dx: 0, dy: 12)))
    #expect(!HoverTracker.isStill(drawn: drawn, read: drawn.offsetBy(dx: 3, dy: 0)))
    #expect(!HoverTracker.isStill(drawn: drawn, read: nil))
}

// ScrollLagTests
@Test func onlyMeasuredAppsHaveACeiling() {
    #expect(ScrollLag.ceiling(for: "com.example.unmeasured") == nil)
    #expect(ScrollLag.ceilings.values.allSatisfy { $0 >= .milliseconds(50) && $0 <= .seconds(5) })
    // one exact assertion per measured app, with the value the controller hands over
}
```

- [ ] **Step 2: Run** the App suite; expected: FAIL to compile.
- [ ] **Step 3: Implement.** Times for `ScrollSettle` are durations from one `ContinuousClock.Instant` taken at `start()`, through the controller's injected clock.
- [ ] **Step 4: Run** the App suite; expected: PASS.
- [ ] **Step 5: Commit** "Hide underlines on a scroll and bring them back once the app's bounds have settled".

---

### Task 10: Review mode in the app

**Per-task review** (it holds keys system-wide).

**Depends on:** Task 4 (`reviewHotkey`), Task 6 (`ReviewMode`), Task 8 (the card), Task 9 (the controller as it then is)

**Files:**
- Create: `Skald/Overlay/ReviewKeys.swift`, `Skald/Overlay/Announcer.swift`
- Modify: `Skald/HotkeyCenter.swift`, `Skald/Overlay/OverlayController.swift`, `Skald/CompositionRoot.swift` (the shortcut, the announcer, pause), `Skald/Settings/GeneralPane.swift` (`HotkeyRecorder` made internal so Task 11's pane can use it)
- Test: `SkaldTests/ReviewKeysTests.swift`, `SkaldTests/ReviewAnnouncementTests.swift`

**Interfaces:**
- Consumes: `ReviewMode` (Task 6); `IssueCardModel.label`, `reviewing`, `copyFix()`, `accept(alternative:)`, `dismiss()` (Task 8).
- Produces:
  ```swift
  // HotkeyCenter: tokens instead of unregisterAll for one hotkey
  struct HotkeyToken: Hashable
  func register(_ h: Hotkey, action: @escaping @MainActor () -> Void) -> HotkeyToken?   // nil: the system refused it
  func unregister(_ token: HotkeyToken)
  protocol KeyRegistering: AnyObject {       // HotkeyCenter conforms
      func register(_ h: Hotkey, action: @escaping @MainActor () -> Void) -> HotkeyToken?
      func unregister(_ token: HotkeyToken)
  }

  /// The six keys, held only between `hold` and `release`.
  final class ReviewKeys {
      static let bindings: [(key: ReviewMode.Key, hotkey: Hotkey)]   // → 124, ⇥ 48 → .next; ← 123 → .previous; ↩ 36 → .accept; ⌫ 51 → .dismiss; esc 53 → .leave; modifiers 0
      init(registrar: any KeyRegistering)
      var isHolding: Bool
      /// All six or none: false, with nothing held, when any registration fails.
      func hold(_ pressed: @escaping @MainActor (ReviewMode.Key) -> Void) -> Bool
      func release()
  }

  protocol Announcing { func announce(_ text: String) }
  struct VoiceOverAnnouncer: Announcing     // NSAccessibility.post(element: NSApp, notification: .announcementRequested, …) at high priority
  static func OverlayController.announcement(label: String, index: Int, count: Int) -> String   // "Grammar: word, change to wordt. 2 of 5"
  func OverlayController.toggleReview()     // the shortcut's action
  ```
- The controller owns one `ReviewMode` and executes its effects: `.show(id)` opens that issue's card alone, `reviewing`, anchored to its drawn word, else to its freshly read bounds, else to the badge, else to the field's frame, and announces it; `.accept(id)` runs the card's `accept()` and reports the outcome with `finished(…, at:)`; `.copy(id)` calls `copyFix()`; `.dismiss(id)` calls `dismiss()`; `.close` releases the keys and closes cards that are ready. Opening: `toggle` first, and only if its effects open the mode are the keys held; if `hold` fails the mode is `left()` at once, nothing is shown and `Log.ui` says so. Inputs: a snapshot for the same field → `issuesChanged`; a field change, `clickedElsewhere`, a pause and `stop()` → `left()`; a text change → `edited(at:)`. A review card is not closed by pointer moves or by a scroll (its anchor is re-read on the next `.show`), and a hover opens no card while the mode is open.
- The composition root registers `reviewHotkey` beside the panel's, each with its own token, re-registers the one that changed, and puts a refusal in `model.reviewHotkeyNote` (same wording as the panel's note).

- [ ] **Step 1: Write the failing tests.** `FakeRegistrar` records registrations and refuses the key codes it is told to.

```swift
// ReviewKeysTests
@Test func holdingRegistersTheSixKeysAndReleasingFreesThem() {
    let registrar = FakeRegistrar()
    let keys = ReviewKeys(registrar: registrar)
    #expect(keys.hold { _ in } && keys.isHolding)
    #expect(Set(registrar.held.map(\.keyCode)) == [124, 48, 123, 36, 51, 53])
    #expect(registrar.held.allSatisfy { $0.modifiers == 0 })
    keys.release()
    #expect(registrar.held.isEmpty && !keys.isHolding)
}

@Test func aKeyThatDoesNotRegisterKeepsTheModeClosedAndFreesTheRest() {
    let registrar = FakeRegistrar(refusing: [36])
    let keys = ReviewKeys(registrar: registrar)
    #expect(!keys.hold { _ in })
    #expect(registrar.held.isEmpty && !keys.isHolding)
}

@Test func aPressReportsItsKey() {
    let registrar = FakeRegistrar()
    var pressed: [ReviewMode.Key] = []
    _ = ReviewKeys(registrar: registrar).hold { pressed.append($0) }
    for code: UInt16 in [124, 48, 123, 36, 51, 53] { registrar.press(code) }
    #expect(pressed == [.next, .next, .previous, .accept, .dismiss, .leave])
}

@Test func holdingTwiceRegistersOnce()        // a second hold while holding returns true and adds nothing

@Test func noKeyIsHeldOnceTheModeIsClosed() async {
    // an OverlayController on fakes (the rig CardPanelTests uses), a field with two issues, review toggled open:
    // registrar.held.count == 6; then for each of: toggle again, a snapshot for another field, a snapshot with no
    // issues, clickedElsewhere, stop() → registrar.held.isEmpty
}

// ReviewAnnouncementTests
@Test func aStepIsAnnouncedWithItsPlace() {
    #expect(OverlayController.announcement(label: "Grammar: word, change to wordt", index: 1, count: 5) == "Grammar: word, change to wordt. 2 of 5")
}
```

  If the controller can't be built on fakes without changing its dependencies beyond an injected `KeyRegistering` and `Announcing`, `noKeyIsHeldOnceTheModeIsClosed` drives a small `ReviewSession` (the `ReviewMode`, the `ReviewKeys` and the effect switch) extracted from the controller instead; say which in the report.

- [ ] **Step 2: Run** the App suite; expected: FAIL to compile.
- [ ] **Step 3: Implement.** `HotkeyCenter` keeps one Carbon handler; `unregisterAll` stays for `stop()`.
- [ ] **Step 4: Run** the App suite; expected: PASS.
- [ ] **Step 5: Commit** "Step through the issues from the keyboard".

---

### Task 11: The menu and Settings: two pauses, the legend, hidden kinds, the shortcut, and where Skald can't work

**Depends on:** Task 4 (`pause(for:)`, `hiddenKinds`, `reviewHotkey`), Task 7 (`LegendView`, `CategoryPalette`), Task 10 (`HotkeyRecorder`, `reviewHotkeyNote`)

**Files:**
- Create: `Skald/Settings/SuggestionsPane.swift`
- Modify: `Skald/StatusItemController.swift`, `Skald/CompositionRoot.swift`, `Skald/Settings/SettingsWindow.swift`, `Skald/Overlay/OverlayController.swift` (reports the focused field's capabilities), `Packages/SkaldPlatform27/Sources/SkaldPlatform27/Access/FocusMachine.swift`, `Access/FieldObserver.swift`, `Access/SystemTextAccess.swift`
- Test: `SkaldTests/StatusTitleTests.swift`, `SkaldTests/StatusMenuTests.swift`, the Platform suite that tests `FocusMachine` (`rg -l FocusMachine Packages/SkaldPlatform27/Tests`)

**Interfaces:**
- Produces:
  ```swift
  // Platform: the frontmost observed app while it answers no focused element; nil once it gives one or another app is frontmost.
  FocusMachine.Step.unreadable(String?)
  SystemTextAccess.unreadableApp: AsyncStream<String?>

  enum FieldAccessNote: Equatable {
      case cantRead, badgeOnly, cantShow
      var line: String        // the "Menu lines" row
      static func resolve(unreadable: Bool, focused: Bool, capabilities: AccessCapabilities?) -> FieldAccessNote?
  }
  func StatusState.menuLines(note: FieldAccessNote?) -> [String]
  StatusItemController.Actions.pause: (TimeInterval) -> Void          // replaces pauseForAnHour
  OverlayController.onFieldCapabilities: ((AccessCapabilities?) -> Void)?   // nil when no field is focused
  ```
- `resolve`: `.cantRead` when `unreadable`; else nil without a focused field or its capabilities; `.badgeOnly` with `.fieldFrame` and no `.rangeBounds`; `.cantShow` with neither; nil with `.rangeBounds`.
- `menuLines`: paused or no Accessibility → `[title]`; using Claude or Claude in trouble → `[title, detail?, note?]`; otherwise `[note?, title]`; nils left out. `menuNeedsUpdate` adds these lines disabled, in order, in place of the heading and detail.
- The machine emits `.unreadable(app)` when an activation or retry query is `.missing` for the observed frontmost app, and `.unreadable(nil)` with the next `.element` result or activation; never twice in a row with the same value.
- The menu: "Pause for 30 Minutes" (`pause(30 * 60)`) and "Pause for an Hour" (`pause(60 * 60)`) where "Pause for an Hour" was; a submenu "Underline Colours" before "Settings…", its three items disabled, each with a 10 pt dot image in `CategoryPalette.color` and the category's title.
- `SuggestionsPane` (tab "Suggestions", `sparkles.rectangle.stack` or another existing SF Symbol): "Underlines" with `LegendView`; "Review" with the shortcut recorder on `reviewHotkey`, `reviewHotkeyNote`, and the line "Steps through the issues in the focused field: → or ⇥ next, ← previous, ↩ accept, ⌫ dismiss, esc to leave."; "Hidden suggestions" with one toggle per hidden kind (its title; off brings it back through `model.show`), or "Nothing is hidden." when the set is empty.

- [ ] **Step 1: Write the failing tests.**

```swift
// StatusTitleTests
@Test func theNoteSaysWhereSkaldCantWork() {
    #expect(FieldAccessNote.resolve(unreadable: true, focused: false, capabilities: nil) == .cantRead)
    #expect(FieldAccessNote.resolve(unreadable: false, focused: true, capabilities: [.read, .fieldFrame]) == .badgeOnly)
    #expect(FieldAccessNote.resolve(unreadable: false, focused: true, capabilities: [.read]) == .cantShow)
    #expect(FieldAccessNote.resolve(unreadable: false, focused: true, capabilities: [.read, .rangeBounds, .fieldFrame]) == nil)
    #expect(FieldAccessNote.resolve(unreadable: false, focused: false, capabilities: nil) == nil)
    #expect(FieldAccessNote.cantRead.line == "Skald can't read text in this app")
    #expect(FieldAccessNote.badgeOnly.line == "Issues are listed at the badge here")
    #expect(FieldAccessNote.cantShow.line == "Skald can't show issues in this app")
}

@Test func theNoteIsTheFirstLineUnlessClaudesLineIs() {
    #expect(StatusState.onThisMac.menuLines(note: .badgeOnly) == ["Issues are listed at the badge here", "Checking on this Mac"])
    #expect(StatusState.onThisMac.menuLines(note: nil) == ["Checking on this Mac"])
    #expect(StatusState.usingClaude([.nl], lastFailure: .unreachable).menuLines(note: .badgeOnly)
        == ["Dutch checks use Claude", "Last check failed: Claude unreachable", "Issues are listed at the badge here"])
    #expect(StatusState.noAccessibility.menuLines(note: .cantRead) == ["Skald needs Accessibility access"])
    #expect(StatusState.paused(until: date).menuLines(note: .cantRead).count == 1)
}
```

  In `StatusMenuTests`: the menu holds "Pause for 30 Minutes" and "Pause for an Hour" when not paused and their actions pass 1800 and 3600; "Underline Colours" has a submenu titled "Spelling", "Punctuation", "Grammar". In the `FocusMachine` suite: an activation answered `.missing` yields `.unreadable("com.example.app")` among its steps, a later `.element` result yields `.unreadable(nil)`, and a second `.missing` yields no second `.unreadable`.

- [ ] **Step 2: Run** the App and Platform suites; expected: FAIL to compile.
- [ ] **Step 3: Implement**, and wire the root: it keeps the last unreadable app and the last capabilities, and refreshes the status on each.
- [ ] **Step 4: Run** the App and Platform suites; expected: PASS.
- [ ] **Step 5: Commit** "Say in the menu where Skald can't work, and add the legend, two pauses and the Suggestions pane".

---

### Task 12: Changelog and documentation

**Depends on:** Tasks 1 to 11

**Files:**
- Modify: `CHANGELOG.md` (`## [Unreleased]`), `README.md` (the overlay's description, if it has one), `docs/superpowers/specs/2026-11-20-skald-upgrade-design.md` (a dated "Decided in stage 2's plan" list under "Stage 2: overlay" holding the five rulings above and the measured ceilings), `AGENTS.md` (one line under Commands: the scroll probe's launch arguments)

- [ ] **Step 1: Write** the changelog entries. Added: three underline colours with a legend; the card's kind line, alternatives and "Hide suggestions like this"; the counter in every checked field; review mode with its shortcut and keys; the menu line where Skald can't work; VoiceOver labels; "Pause for 30 Minutes". Changed: "Ignore" is "Dismiss", "Never flag" is "Add to dictionary". Fixed: underlines drawn off the word after a scroll (they hide and come back; in an app Skald hasn't measured they stay hidden until the next edit or caret move).
- [ ] **Step 2: Run** `/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'`; expected: PASS (the changelog tool still parses the file).
- [ ] **Step 3: Commit** "Describe the overlay's categories, card, review mode and scroll handling".

---

## Final verification (controller, on the last commit)

1. `swift test --package-path Packages/SkaldCore`, `swift test --package-path Packages/SkaldPlatform27`, the App suite, the script tests; report each as passed/total.
2. Release build, then `scripts/verify-app build/dd.noindex/Build/Products/Release/Skald.app`.
3. Run it as its user will (the `run` skill): install the Release build over the backed-up `/Applications/Skald.app`, type the synthetic sample in TextEdit, and check that underlines show in three colours, the badge counts, the review shortcut opens a card and esc frees the keys (typing ↩ in TextEdit afterwards makes a new line). Restore Michael's build. Record the commands and what they showed in the ledger.
4. The final whole-branch review (`sp-architect`), then the fix wave, then 1 and 2 again on the last commit.

## Memory, before and after (controller)

As stage 1's plan, with `build/baseline/Skald.app` (commit `d4c47fe`) against the new Release build: idle after 60 s, and after `open -a TextEdit build/memory-sample.txt` and 60 s. Four `footprint` figures, with the commits, go in the PR under "Memory".

## Owed (Michael)

- **Notes' scroll lag:** with a long note focused, `open /Applications/Skald.app --args --probe-scroll` from a Debug build, scroll 20 times each with the wheel, the trackpad and a flick, quit Skald; the ceiling is in `~/Library/Application Support/com.michaelrigart.skald/probe/scroll-lag.json`. Until then Notes' underlines stay hidden after a scroll until the next edit or caret move. The same holds for any app the controller could not measure.
- **The spec's manual checks:** the three colours and the legend in light and dark mode; smooth trackpad scrolling in a Zen textarea, underlines never drawn off the word; review mode end to end in Notes, Zen and Slack; one pass with VoiceOver.
- **The five rulings** above, to confirm or overturn.
