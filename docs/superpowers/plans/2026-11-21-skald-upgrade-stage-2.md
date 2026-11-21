# Skald Upgrade, Stage 2 (Overlay) Implementation Plan

**Status:** In progress

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. In this repository the `plan-run` skill runs plans and takes precedence over both.

**Goal:** Underlines in three colours by category with a legend; a card that names the kind of issue, offers alternatives and can hide a kind; a counter in every checked field and review from the keyboard; underlines that hide on a scroll and come back in the right place; a menu line where Skald can't work, and VoiceOver labels.

**Architecture:** Skald classifies every kept edit itself (`IssueClassifier` → `IssueKind`, three fixed `IssueCategory` values) and the pipeline publishes it on `Issue`, with the spell checker's other guesses as `alternatives`, a `checked` flag on the snapshot, and hidden kinds filtered out. Two pure state machines in `SkaldCore` carry the new behaviour: `ScrollSettle` (hide on scroll, show once reads agree across twice the app's measured lag) and `ReviewMode` (a position in the text, keys, the wait for the recheck after an accept, the ways out). `OverlayController` executes their actions; the keys are Carbon hotkeys held only while the mode is open. The lag per app comes from a probe mode run first.

**Tech Stack:** Swift 6, Swift Testing, SwiftPM packages `SkaldCore` (Foundation and Observation only) and `SkaldPlatform27`, the AppKit/SwiftUI app target, xcodegen, Carbon hotkeys.

**Spec:** `docs/superpowers/specs/2026-11-20-skald-upgrade-design.md`, "Stage 2: overlay" and the sections it relies on (Goals 4 to 8, Non-goals, Anti-goals, Constraints, "Left to the builder"). v1's rules: `docs/superpowers/specs/2026-11-02-skald-design.md`. Stage 1 is built; nothing here changes an engine, a route or what is sent.

**Base:** `feat/skald-overlay`, started from `feat/skald-upgrade` at `d4c47fe`. When `feat/skald-upgrade` moves, merge it in (never rebase pushed work).

**Order:** the tasks run serially, 1 to 14; each `Depends on:` names the tasks whose interface it uses.

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
| Classification, first match wins | 1. the edit's words, joined without anything between them, are the same on both sides → `punctuation` (so an apostrophe or a space inside a word counts: "Lets" → "Let's", "fallback" → "fall back", "it's" → "its"); 2. the same but for letter case → `capital`; 3. the same but for diacritics (case may differ too) → `accent`; 4. a spelling issue, or an original word the dictionary rejects that is not a function word (the guard's own test, `EditGuard.swift:98`) → `spelling`; 5. a deleted single word equal, ignoring case, to the word before or after it → `repeatedWord`; 6. Dutch, one word for one word, equal once a final "dt", "d" or "t" is cut from each and at least two letters remain, and with the same lemma when the facts hold a lemma for both → `verbForm`; 7. `grammar`. "Words" are `EditGuard.words(in:)` without lowercasing. Rules 1 to 3 compare the joined words, so spacing between words and punctuation inside a word count as punctuation. |
| Hideable kinds | `capital`, `accent`, `punctuation`, `repeatedWord`, `verbForm`. Never `spelling` or `grammar`. |
| Colours (sRGB) | One palette for both appearances, because the text under an underline follows the page or the app, not the system: Spelling `#D55E00`, Grammar `#0072B2`, Punctuation `#8B5CF6`. Computed: each is at least 3.2:1 against both white and `#1E1E1E`, and every pair stays at least 0.35 apart in sRGB under Machado's (2009) full protanopia, deuteranopia and tritanopia. Punctuation is also drawn dotted (2 pt on, 2 pt off), a second cue on a 2 pt line. |
| Badge | At the bottom-right corner of every checked field whose app gives the field's frame. Zero issues: a grey tick at 60 % opacity, no click action. While the same field is being rechecked (a snapshot that isn't `checked`, Skald not paused) the badge keeps what it showed, so it doesn't blink on every keystroke. |
| "Checked" | `IssueSnapshot.checked`: not paused, and every chunk of the paragraph holding the caret in the focused field's latest read has a stored spelling or model result; when the caret is in no paragraph (an empty line), any stored result for the field counts. Narrowed during the run: after Skald's own write, the other paragraphs' results must not count as the written paragraph's recheck. |
| Alternatives | A spelling issue carries up to 2 more guesses after the first (three in all), each a guard-kept edit over the same range. The checker returns every guess; the pipeline keeps the first 2 the guard keeps. |
| Review shortcut | `⌃⌥R` (`Hotkey(keyCode: 15, modifiers: control | option)`), setting `reviewHotkey`. Pressed again, it leaves the mode. |
| Review keys | → `124`, ⇥ `48` next; ← `123` previous; ↩ `36` accept; ⌫ `51` dismiss; esc `53` leave; no modifiers. All six register or the mode does not open. While an accept is applied or the recheck awaited all six stay held and only esc acts, so a ↩ can't reach the app mid-write. A key still down when the mode ends stays held until it is released, at most 1 s, so its auto-repeat can't reach the app. Checked 2026-11-21 on macOS 27.2: `RegisterEventHotKey` accepts all six without modifiers (status 0). |
| Review, which issue | Next and previous are the shown issue's neighbours in the list while it is still listed (so two issues at one offset are both reachable); otherwise the first issue starting after the position, or the last starting before it. At either end the key does nothing. After a dismiss, or when the shown issue goes: the first remaining issue at or after the position, else the last before it, else the mode ends. An accept whose write is not confirmed ends the mode and leaves v1's card with its reason. In an app without a clean write, ↩ copies the fix and stays. |
| Review, after an accept | Skald's own write makes the pipeline hide the field's issues and check the paragraph again (`CheckScheduler` suspends on the edit; a `ParagraphKey` holds the paragraph's text). So after a confirmed write the mode waits: a card says "Checking…", the keys stay held, esc leaves. It goes on at the first `checked` snapshot for the field, to the first issue at or after the position, else the last before it, and ends when that snapshot has none or after `ReviewMode.recheckWait` = 6 s (Claude's 5 s timeout and the pause). **This changes the spec's "The wait is v1's write"; see Rulings.** |
| Edits in review | While a write is applied or the recheck is awaited, edits are Skald's own and ignored. While a card is shown, any edit leaves the mode. |
| Scroll rule | `ScrollSettle(ceiling:)`. While it hides, only a text or caret change brings underlines back early; a new snapshot or a window move updates the badge and leaves them hidden. Reads every `ceiling` after the last scroll event; underlines show when a read taken `2 × ceiling` or more after the last scroll event equals the read before it. Then 3 more reads, one per `ceiling`; one that differs hides and starts over from that moment. At most 20 reads follow one scroll event, counted across every restart a differing read causes; once they are spent it returns `[]` to every read and stays hidden until the next text or caret change or scroll. `ceiling == nil` (unmeasured): hidden until the next text or caret change. |
| Lag ceiling | Per app: the largest lag measured, rounded up to 50 ms, at least 50 ms; nil when fewer than 20 gestures of any of the three kinds were measured or one never settled within 5 s. The table lives in `ScrollLag.ceilings` and holds only measured apps. |
| Which scrolls | Every `scrollWheel` event counts, whatever window is under the pointer: a page can scroll its text area from anywhere, and Skald doesn't ask which window got the event. The cost: scrolling another app's window hides an unmeasured app's underlines until the next edit or caret move (see Rulings). |
| Hover check | Before a hover card opens, the word's bounds are read again; more than 2 pt from the drawn place on either axis, or unreadable, redraws instead. |
| Pause | Menu: "Pause for 30 Minutes", "Pause for an Hour". Settings keeps one button, "Pause for an Hour". |
| Menu lines | "Skald can't read text in this app" (the frontmost app answers no focused element), "Issues are listed at the badge here" (frame, no range bounds), "Skald can't show issues in this app" (neither; added, see Rulings). While a request can leave (stage 1's "… checks use Claude" line), that line stays first and this one follows it; in every other state this one is first; paused or without Accessibility, it isn't shown. "Can't read" is said only once the focus retries have run out. |
| Legend | Menu: submenu "Underline Colours" with three items, each a coloured dot and the category's name (enabled without an action, so the dots aren't dimmed). Settings: a new "Suggestions" pane with the legend, the hidden kinds and the review shortcut. |
| Labels | `"‹Category›: ‹original›, change to ‹replacement›"`; an insertion `"‹Category›: add ‹replacement›"`; a deletion `"‹Category›: remove ‹original›"`. Review steps announce the label and `"‹n› of ‹count›"`. |
| Settings storage | Version stays 2 (no value changes shape). New keys `hiddenKinds` (a sorted array of kind names, `[]`; an unknown or unhideable name is dropped) and `reviewHotkey`. A settings change that touches only these two republishes and does nothing else: no new epoch, no recheck, no cancelled request. |
| Memory | As stage 1: `/usr/bin/footprint -p Skald`, idle and after a TextEdit check, baseline (`d4c47fe`) against the new Release build; numbers go in the PR. |

## Rulings made while planning

**One changes the spec and waits for Michael:**

- **Review mode waits for the recheck after an accept.** The spec says "when the write is confirmed the mode moves to the next issue after that position" and "The wait is v1's write". In the code as it is, Skald's own write hides the field's issues until the paragraph is read and checked again, so nothing is there to move to. This plan adds the wait (the "Review, after an accept" row). The alternative keeps the spec's words: carry the paragraph's other issues across Skald's own write in the tracker (re-key them, shift every offset), which is a larger change to the pipeline. Built as recommended; recorded in the spec as pending his confirmation.

**The rest stay inside the spec and are listed in the PR:**

- **Two "first lines".** Stage 1's review says the Claude line is first while a request can leave; stage 2 says the first line names an app Skald can't work in. While a request can leave, the privacy line keeps the first place and the app line follows it.
- **A third app line**, "Skald can't show issues in this app", for an app that gives text but neither range bounds nor a frame. The spec names two; Goal 8 covers the third.
- **"Only esc is taken" while a write is applied** is read as "only esc acts": the other keys stay held, or a ↩ pressed during a paste would go to the app.
- **After an accept or a dismiss, with nothing after the position,** the mode goes to the last issue before it rather than ending while issues remain.
- **Punctuation is dotted as well as coloured,** a second cue beside colour.
- **Every scroll counts,** whatever window it happens in; the cost is in the "Which scrolls" row.
- **The badge keeps its last count while the field is rechecked,** so a count can be a keystroke old.
- **Review mode ends when the first checked snapshot after an accept is empty,** even if Claude's answer for that paragraph is still on its way; the shortcut opens it again.

## Review Focus

1. **A review key that failed to register while the others did**: ↩ would then reach the app and could send a message. Expected: all six or none, and the mode stays closed. Task 10, `aKeyThatDoesNotRegisterHoldsNothing`; Task 11, `theModeStaysClosedWhenTheKeysAreRefused`.
2. **A key still held after the mode ended by a way other than esc** (focus change, click elsewhere, a foreign edit, the last issue accepted, the recheck never arriving, Skald paused, the overlay stopped), or a key still down at that moment repeating into the app. Expected: none held, and a key that is down is let go only on its release. Task 6, `everyWayOutClosesTheMode`; Task 10, `aKeyStillDownIsHeldUntilItIsReleased`; Task 11, `noKeyIsHeldOnceTheModeIsClosed`.
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
      public var lag: Duration?                             // nil before any scroll, and when no sample since the last scroll had bounds
      public func isSettled(at now: Duration) -> Bool
      public func gaveUp(at now: Duration) -> Bool
      /// One more sample, 3 s after the last scroll event: bounds that differ from the settled ones mean the app caught up late, and the gesture counts as unsettled.
      public static let finalCheck: Duration = .seconds(3)
      public mutating func checkedFinally(_ bounds: CGRect?)
      public var isUnsettled: Bool                          // gave up, or the final check differed
  }
  public enum ScrollLagSummary {
      public static let gestures = 20
      /// nil with fewer than `gestures` lags or any nil (unsettled) among them; else the largest, up to the next 50 ms, at least 50 ms.
      public static func ceiling(_ lags: [Duration?]) -> Duration?
      /// The app's ceiling: the largest of its kinds', nil when any kind has none.
      public static func ceiling(byKind: [ScrollKind: [Duration?]]) -> Duration?
  }
  ```
- The probe (`ScrollLagProbe.run(drive: Bool) async`, main actor): finds the focused field of the frontmost app other than Skald, as the app does (that app's focused element, `EditableResolver.field(for:)`); skips secure fields; on every global `scrollWheel` event classifies it (`momentumPhase` set → momentum, else `hasPreciseScrollingDeltas` → trackpad, else wheel) and samples the bounds of the one-unit range at the caret (the unit before it at the end of the text), with the reader `SystemTextAccess.bounds` uses, every 10 ms on `AXQueue` until the trace settles or gives up, then once more at `finalCheck`. Sampling runs only inside a gesture. A gesture none of whose samples had bounds is dropped and logged as "no bounds"; it is never a lag of zero. Each other finished gesture logs one `PlatformLog.probe` line: bundle id, kind, lag in ms or "unsettled". On quit (after 10 minutes without `--drive`, or when a drive ends) it writes `~/Library/Application Support/com.michaelrigart.skald/probe/scroll-lag.json`: per bundle id and kind the lags in ms (null for unsettled) and the app's ceiling in ms or null.
- `--drive`: for each kind in turn, 20 gestures alternating down and up. Its events are posted from a `CGEventSource(stateID: .privateState)`, so they don't count as hardware input; each gesture starts only when `CGEventSource.secondsSinceLastEventType(.hidSystemState, …)` for any input is 8 s or more (it waits otherwise). Before the first gesture it warps the pointer to the centre of the field's frame and clicks there once, so the caret's unit is in view; the pointer is put back when the drive ends. Every gesture stays under half the field's height, so the sampled unit stays in view. Wheel: 3 line events of ±1, 20 ms apart. Trackpad: 8 pixel events of ±5 with scroll phases began, changed, ended, 16 ms apart. Momentum: a trackpad gesture, then 10 pixel events with momentum phases begin, continue, end and deltas falling from 5 to 1. The next gesture starts after the final check. A drive has no time limit.

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

@Test func aGestureWithoutBoundsHasNoLagAndALateCatchUpIsUnsettled() {
    var blind = ScrollLagTrace()
    blind.scrolled(.wheel, at: .zero)
    blind.sampled(nil, at: .milliseconds(10))
    #expect(blind.lag == nil)
    var late = ScrollLagTrace()
    late.scrolled(.wheel, at: .zero)
    late.sampled(a, at: .milliseconds(10))
    #expect(!late.isUnsettled)
    late.checkedFinally(b)
    #expect(late.isUnsettled)
}

@Test func theCeilingIsTheLargestLagRoundedUpAndNeedsTwentySettledGestures() {
    let twenty: [Duration?] = Array(repeating: .milliseconds(40), count: 19) + [.milliseconds(101)]
    #expect(ScrollLagSummary.ceiling(twenty) == .milliseconds(150))
    #expect(ScrollLagSummary.ceiling(Array(repeating: .zero, count: 20)) == .milliseconds(50))
    #expect(ScrollLagSummary.ceiling(Array(twenty.dropLast())) == nil)
    #expect(ScrollLagSummary.ceiling(Array(twenty.dropLast()) + [nil]) == nil)
    #expect(ScrollLagSummary.ceiling(byKind: [.wheel: twenty, .trackpad: twenty, .momentum: Array(repeating: .milliseconds(200), count: 20)]) == .milliseconds(200))
    #expect(ScrollLagSummary.ceiling(byKind: [.wheel: twenty, .trackpad: twenty]) == nil)
}
```

  and in `LaunchModeTests`: `--probe-scroll` from `/Applications` resolves to `.scrollProbe` and from elsewhere to `.wrongPlace`. The argument is read under `#if DEBUG`, as `--probe` is; `scripts/verify-app` is what proves a Release build has no probe.

- [ ] **Step 2: Run** the Platform suite filtered to `ScrollLagTraceTests`; expected: FAIL, the types don't exist.
- [ ] **Step 3: Implement** the trace and summary, then the probe and the launch argument as the Interfaces say. The probe is `#if DEBUG`; `scripts/verify-app` must still find no probe in a Release build.
- [ ] **Step 4: Run** the Platform suite and the App suite; expected: PASS. Build Release and run `scripts/verify-app build/dd.noindex/Build/Products/Release/Skald.app`; expected: it passes.
- [ ] **Step 5: Commit** "Add a probe mode that measures how long an app's bounds lag behind a scroll".

**Measurement (controller, live, after the commit; not an implementer's step).** Build Debug, back up `/Applications/Skald.app` to `build/installed-backup/Skald.app`, install the Debug build. Make `build/scroll-probe/sample.txt` (the `Eval/seed.jsonl` texts repeated to 300 lines) and `build/scroll-probe/sample.html` (a page with one `<textarea autofocus rows="12">` holding the same text, itself taller than the window). Quit any running Skald first (`open --args` passes nothing to a running app). For TextEdit and then Zen: open the sample, wait for focus, `open /Applications/Skald.app --args --probe-scroll --drive`, wait for it to quit, copy `scroll-lag.json` to `.superpowers/upgrade-evidence/scroll-lag-<app>.json`. Close the documents without saving, restore Michael's build. Notes needs a note in Michael's own data, and a synthetic trackpad gesture may not take the path a real one does in Zen, so both are his steps (see "Owed"); a larger ceiling he measures replaces the driven one. The ceilings measured go into Task 9's table; an app that could not be measured stays out of it. If `open` or the Accessibility grant is refused, skip the measurement, leave the table empty and report it as owed.

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
      /// `facts` are the oracle's for the edit's words, as the guard gets them; rule 4 reads `misspelled` and the guard's function-word test, rule 6 reads `lemmas`.
      public static func kind(of edit: Edit, in paragraph: String, language: Language, source: IssueSource, facts: WordFacts) -> IssueKind
  }
  Row.kind: IssueKind   // a required `kind:` argument on both initialisers, after `expected`
  ```

- [ ] **Step 1: Write the failing tests** in `IssueClassifierTests`. A helper `kind(_ text: String, _ revised: String, _ language: Language = .en, source: IssueSource = .model, misspelled: Set<String> = [], lemmas: [String: String] = [:])` classifies the first edit of `TextDiff.edits(from:to:)` with `WordFacts(misspelled:lemmas:)`.

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
    #expect(kind("Thanks all good.", "Thanks, all good.") == .punctuation)
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
    #expect(kind("Het is hart.", "Het is hard.", .nl, lemmas: ["hart": "hart", "hard": "hard"]) == .grammar)   // not one verb
    #expect(kind("Het word morgen.", "Het wordt morgen.", .nl, lemmas: ["word": "worden", "wordt": "worden"]) == .verbForm)
    #expect(kind("I didn do it.", "I did do it.", misspelled: ["didn"]) == .grammar)   // a misspelled function word, as the guard reads it
}
```

  Then one parameterised test over `outcomeTable`, `everyRowOfTheOutcomeTableHasItsKind`: the row's first edit classified with the suite's existing facts for that row (the way `EditGuardTests` obtains them) equals `row.kind`. Fill every row's `kind:` by the "Values" rules, reading the row, not by running the classifier. `GuardOutcomeSystemTests` gains the same assertion with `SystemWordOracle`'s facts.

- [ ] **Step 2: Run** the Core suite filtered to `IssueClassifierTests`; expected: FAIL, the types don't exist.
- [ ] **Step 3: Implement** `IssueKind` and `IssueClassifier.kind` by the seven rules, in their order. Words come from `Tokenizer`, as in `EditGuard.words(in:)`, kept in their case; diacritics fold with `.diacriticInsensitive`; the neighbour of a deleted word is the nearest word token on either side of `edit.tokenSpan`; the function-word test is the guard's (`EditGuard.isFunctionWord`, made internal).
- [ ] **Step 4: Run** the Core suite and the Platform suite; expected: PASS. A row whose kind the real dictionary and the fake disagree on is reported, not special-cased.
- [ ] **Step 5: Commit** "Classify every edit into a category and a kind".

---

### Task 3: Issues carry their kind and alternatives, and the snapshot says a field is checked

**Per-task review** (Tasks 4, 6, 7, 8 and 10 use it).

**Depends on:** Task 2 (`IssueKind`, `IssueClassifier`)

**Files:**
- Modify: `Packages/SkaldCore/Sources/SkaldCore/Issues/Issue.swift`, `Issues/IssueTracker.swift`, `Platform/SpellingChecking.swift`, `Pipeline/CheckPipeline.swift` (`IssueSnapshot`, `spell`, the model path's `anchored`, `accept`, `publish`)
- Modify: `Packages/SkaldPlatform27/Sources/SkaldPlatform27/Language/SpellingChecker.swift`, `Eval/EvalRunner.swift:240` (`.map(\.edit)`), `Skald/Overlay/OverlayController.swift:100` (the rebuilt snapshot passes `checked` on)
- Test: `Packages/SkaldCore/Tests/SkaldCoreTests/CheckPipelineTests.swift`, `IssueTrackerTests.swift`, `Support/FakeSpelling.swift`, `Packages/SkaldPlatform27/Tests/SkaldPlatform27Tests/SpellingTests.swift`, `EvalRunnerTests.swift` (`ScriptedSpelling` conforms to the protocol), `GuardOutcomeSystemTests.swift` (`britishGuessIsKept` passes `.map(\.edit)`); `SkaldTests/Support/IssueFixture.swift` (a `kind:` and `alternatives:` argument, defaulted)

**Interfaces:**
- Produces:
  ```swift
  public struct SpellingFlag: Equatable, Sendable {
      public let edit: Edit            // the first guess, as today (an empty replacement when there is none)
      public let alternatives: [Edit]  // every further guess over the same `range`, in the checker's order
      public init(edit: Edit, alternatives: [Edit] = [])
  }
  protocol SpellingChecking { func flags(in p: Paragraph, language: Language, neverTouch: Set<String>) async -> [SpellingFlag] }

  Issue.kind: IssueKind            // init argument `kind: IssueKind? = nil`: nil means .spelling for a spelling issue, .grammar for a model one
  Issue.alternatives: [Edit]       // init argument `alternatives: [Edit] = []`; relative to `chunk`, like `edit`
  IssueSnapshot.checked: Bool      // init(field:issues:checked:), no default: every caller says which
  CheckPipeline.maxAlternatives = 2   // public static
  IssueTracker.hasResults(in field: FieldID) -> Bool
  CheckPipeline.accept(_ id: UUID, alternative: Int? = nil) async -> ReplaceOutcome
  ```
- `Issue` stays `Hashable`; `IssueTracker.revalidate` carries `kind` and `alternatives` over; the tracker's ignore and twin rules keep comparing `edit` only.
- The pipeline: a spelling issue's kind is `IssueClassifier.kind(…, source: .spelling, misspelled: [])`. A model issue's kind uses the facts of one `oracle.facts(for: EditGuard.words(in: kept), language:)` call, made right after `ModelAnswer.judge` and before the route lookup at `CheckPipeline.swift:524`, so the `isCurrent` and route checks that follow still guard the publish; no call when nothing was kept. A spelling issue is classified with `WordFacts()`. Alternatives: the guesses of a kept flag that `editGuard.resolve(…, source: .spelling, confirmer: nil)` also keeps, in order, cut to `maxAlternatives`.
- `hasResults(in:)`: true once `setSpelling` or `setModel` has run for a key of that field and until that key is cleared, dropped by `revalidate`, or everything is cleared; false while the field is suspended. `publish` sets `checked = !isPaused && hasResults(in: currentField)`.
- `SpellingChecker`: Dutch and French take the checker's guesses after the first; English takes the American guesses the British dictionary accepts, without the first guess chosen. A guess is kept only when it differs from the first and its `TextDiff` edit has the first guess's `range`.

- [ ] **Step 1: Write the failing tests.** `FakeSpelling` takes `[String: [String]]` (guesses per misspelling; the existing `[String: String]` initialiser stays as a convenience). In `CheckPipelineTests`, with the suite's rig and its ways of focusing a field and waiting for a published snapshot. The fake detector needs 20 UTF-16 units for a language and reads Dutch from "Ik heb", so the texts are: English `"I saw teh logs again today."`, Dutch `"Ik heb gezien dat het word uitgerold."`, clean `"Everything here is spelled right."`.

```swift
@Test func aSpellingIssueCarriesItsKindAndTheFirstTwoOtherGuesses() async {
    // spelling: ["teh": ["the", "ten", "tea", "tech"]], field text "I saw teh logs again today."
    #expect(issue.kind == .spelling)
    #expect(issue.edit.replacement == "the")
    #expect(issue.alternatives.map(\.replacement) == ["ten", "tea"])
}

@Test func aModelIssueIsClassified() async {
    // nl model checks on; the engine answers "Ik heb gezien dat het wordt uitgerold."
    #expect(published.issues.map(\.kind) == [.verbForm])
}

@Test func aNeverTouchGuessIsNotOfferedAndTheNextOneIs() async {
    // as the first test, with neverTouch ["ten"]
    #expect(issue.alternatives.map(\.replacement) == ["tea", "tech"])
}

@Test func acceptingAnAlternativeWritesItsText() async {
    #expect(await rig.pipeline.accept(issue.id, alternative: 1) == .replaced)
    // the fake access's last replace call wrote "tea" over "teh", with the issue's `expected`
}

@Test func anUnknownAlternativeIsRefused() async {
    #expect(await rig.pipeline.accept(issue.id, alternative: 2) == .failed)
    // the fake access saw no replace call
    #expect(await rig.pipeline.lastPublished.issues.map(\.id) == [issue.id])   // the issue is still there
}

@Test func theSnapshotSaysCheckedOnceAResultIsIn() async {
    // focus a field holding "Everything here is spelled right." with spelling held:
    //   lastPublished.checked == false, issues == []
    // release spelling: checked == true, issues == []
    // setPaused(true): checked == false
}
```

  In `IssueTrackerTests`: `hasResults(in:)` is false for a fresh tracker, true after `setSpelling([], for: key)`, false after `clear(key)`, false while suspended, and a revalidated issue keeps `kind` and `alternatives`. In `SpellingTests` (tagged `requiresSystem`): a misspelling with several guesses yields alternatives that all differ from `edit.replacement` and from each other and share `edit.range`.

- [ ] **Step 2: Run** the Core suite; expected: FAIL to compile on the new members.
- [ ] **Step 3: Implement** as the Interfaces say. `accept` with an alternative writes that edit's `writeRange` and `writeText` through the same `access.replace(…, expected: issue.expected, …)`; an index out of range returns `.failed` before any write and removes nothing.
- [ ] **Step 4: Run** the Core, Platform and App suites; expected: PASS, with every existing assertion as it was.
- [ ] **Step 5: Commit** "Publish each issue's kind and the spell checker's other guesses, and whether the field was checked".

---

### Task 4: Hidden kinds, the review shortcut and the two pauses in the settings

**Per-task review** (the settings file's format; Tasks 8, 11 and 13 use it).

**Depends on:** Task 3 (`Issue.kind`, the pipeline's `publish`)

**Files:**
- Modify: `Packages/SkaldCore/Sources/SkaldCore/Settings/Settings.swift`, `Pipeline/CheckPipeline.swift` (`publish`, `update(settings:)`), `Skald/SettingsModel.swift`, `Skald/CompositionRoot.swift` and `Skald/Settings/GeneralPane.swift` (only the renamed pause call)
- Test: `Packages/SkaldCore/Tests/SkaldCoreTests/SettingsStoreTests.swift`, `CheckPipelineTests.swift`, `SkaldTests/SettingsModelTests.swift`

**Interfaces:**
- Produces:
  ```swift
  Settings.hiddenKinds: [IssueKind]        // public private(set), default []; unique and sorted by raw value, as `neverTouch` is kept; stored under "hiddenKinds"
  Settings.reviewHotkey: Hotkey            // default Hotkey.review
  Hotkey.review = Hotkey(keyCode: 15, modifiers: controlModifier | optionModifier)   // ⌃⌥R
  Settings.hide(_ kind: IssueKind)         // mutating; ignores a kind that isn't hideable
  Settings.show(_ kind: IssueKind)         // mutating
  SettingsModel.pause(for interval: TimeInterval, now: Date = .now)   // replaces pauseForAnHour(now:)
  SettingsModel.hide(_ kind: IssueKind), SettingsModel.show(_ kind: IssueKind)
  ```
- `publish` leaves out issues whose kind is in `settings.hiddenKinds`; `checked` is unaffected. `update(settings:)` starts with: when the new settings differ from the old only in `hiddenKinds` and `reviewHotkey`, store them, publish and return. No new epoch or read revision, nothing sent to the scheduler, a running request left alone.

- [ ] **Step 1: Write the failing tests.**

```swift
// SettingsStoreTests
@Test func hiddenKindsAndTheReviewShortcutRoundTrip() throws {
    var settings = Settings()
    settings.hide(.verbForm); settings.hide(.punctuation); settings.hide(.grammar); settings.hide(.spelling)
    settings.reviewHotkey = Hotkey(keyCode: 45, modifiers: 0x0100)
    #expect(settings.hiddenKinds == [.punctuation, .verbForm])
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

@Test func hidingAKindLeavesARunningRequestAlone() async {
    // a Claude request held by the rig's request hook; update(settings:) with only hiddenKinds changed;
    // release the request: its answer is published (the request was not cancelled and not sent twice)
}

// SettingsModelTests
@Test func pausingSetsTheEndFromTheInterval() {
    model.pause(for: 30 * 60, now: Date(timeIntervalSince1970: 1000))
    #expect(model.settings.pausedUntil == Date(timeIntervalSince1970: 2800))
}
```

- [ ] **Step 2: Run** the Core suite; expected: FAIL to compile.
- [ ] **Step 3: Implement.** Decode `hiddenKinds` leniently (strings; unknown or unhideable names dropped; then unique and sorted); `reviewHotkey` with `decodeIfPresent`. Callers of `pauseForAnHour` pass `60 * 60`.
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

- [ ] **Step 1: Write the failing tests.** `c = Duration.milliseconds(100)`, readings are strings. The helper `shown(_ reading: String, at: Duration)` returns a settle scrolled at zero, read once at `c` and once more at the given time with the same reading, which shows it.

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

**Per-task review** (Task 11 uses it).

**Depends on:** none (`Issue.fieldRange` and `ReplaceOutcome` exist)

**Files:**
- Create: `Packages/SkaldCore/Sources/SkaldCore/Issues/ReviewMode.swift`
- Test: `Packages/SkaldCore/Tests/SkaldCoreTests/ReviewModeTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ReviewMode: Sendable {
      public enum Key: Sendable, CaseIterable { case next, previous, accept, dismiss, leave }
      public enum Phase: Equatable, Sendable { case closed, showing(UUID), applying(UUID), awaiting(UUID) }
      public enum Effect: Equatable, Sendable {
          case show(UUID)            // open this issue's card
          case accept(UUID)          // start the write; report its outcome with `finished`
          case copy(UUID)            // no clean write here: copy the fix, the card stays
          case dismiss(UUID)
          case wait(UUID, Duration)  // say "Checking…", and call `waitEnded` with this id after the duration
          case close                 // free the keys and close a card that is only offering its choices
      }
      public static let recheckWait: Duration = .seconds(6)
      public init()
      public private(set) var phase: Phase
      /// The field offset the mode stands on: the shown issue's start.
      public private(set) var position: Int
      public var holdsKeys: Bool { phase != .closed }
      /// The shortcut: opens on the first issue (nothing when there is none), or leaves.
      public mutating func toggle(issues: [Issue]) -> [Effect]
      public mutating func key(_ key: Key, issues: [Issue], writes: Bool) -> [Effect]
      /// The outcome of the write `.accept(id)` started.
      public mutating func finished(_ outcome: ReplaceOutcome) -> [Effect]
      /// A snapshot for the focused field.
      public mutating func issuesChanged(_ issues: [Issue], checked: Bool) -> [Effect]
      public mutating func waitEnded(_ id: UUID) -> [Effect]
      /// The field's text changed.
      public mutating func edited() -> [Effect]
      /// A focus change, a click elsewhere, a pause, the overlay stopping.
      public mutating func left() -> [Effect]
  }
  ```
- `issues` is always the focused field's published list, in text order. The rules are the "Values" rows "Review, which issue", "Review, after an accept" and "Edits in review":
  - `finished(.replaced)` → `.awaiting(id)` and `[.wait(id, recheckWait)]`; any other outcome → closed, `[.close]`; outside `.applying` → `[]`.
  - `issuesChanged` while showing an issue that is still listed → `[]`, and `position` moves to that issue's start; while showing one that is gone → the nearest (at or after the position, else the last before), or `[.close]` when the list is empty, whatever `checked` says. While applying → `[]`. While awaiting → `[]` when not `checked`; else the nearest issue, or `[.close]` when there is none.
  - `waitEnded(id)` → `[.close]` only while `.awaiting(id)`.
  - `edited()` → `[.close]` while showing, `[]` otherwise.
  - While applying or awaiting, every key but `.leave` returns `[]`.
  - Every method returns `[]` when closed, except `toggle`.

- [ ] **Step 1: Write the failing tests.** `a`, `b`, `c` are issues in one field starting at 4, 20 and 31; `open(_:)` returns a mode toggled open on a list; `a.moved(to:)` is the same issue (same id) in a chunk that starts elsewhere, so its `fieldRange` starts at the given offset.

```swift
@Test func theShortcutOpensOnTheFirstIssueAndLeavesWhenPressedAgain() {
    var mode = ReviewMode()
    #expect(mode.toggle(issues: []) == [] && !mode.holdsKeys)
    #expect(mode.toggle(issues: [a, b, c]) == [.show(a.id)])
    #expect(mode.phase == .showing(a.id) && mode.position == 4 && mode.holdsKeys)
    #expect(mode.toggle(issues: [a, b, c]) == [.close])
    #expect(mode.phase == .closed && !mode.holdsKeys)
}

@Test func nextAndPreviousMoveToTheNeighbourOrByPositionWhenTheShownIssueIsGone() {
    var mode = open([a, b, c])
    #expect(mode.key(.next, issues: [a, b, c], writes: true) == [.show(b.id)])
    #expect(mode.key(.next, issues: [a, c], writes: true) == [.show(c.id)])        // b went meanwhile: the first after 20
    #expect(mode.key(.next, issues: [a, c], writes: true) == [])
    #expect(mode.key(.previous, issues: [a, b, c], writes: true) == [.show(b.id)])
    #expect(mode.key(.previous, issues: [a, b, c], writes: true) == [.show(a.id)])
    #expect(mode.key(.previous, issues: [a, b, c], writes: true) == [])
}

@Test func twoIssuesAtOneOffsetAreBothReachable() {
    let twin = b.moved(to: 4, id: UUID())                             // a second issue starting at 4
    var mode = open([a, twin, c])
    #expect(mode.key(.next, issues: [a, twin, c], writes: true) == [.show(twin.id)])
    #expect(mode.key(.next, issues: [a, twin, c], writes: true) == [.show(c.id)])
    #expect(mode.key(.previous, issues: [a, twin, c], writes: true) == [.show(twin.id)])
}

@Test func afterAConfirmedWriteTheModeWaitsForTheRecheckAndGoesOn() {
    var mode = open([a, b, c])
    #expect(mode.key(.accept, issues: [a, b, c], writes: true) == [.accept(a.id)])
    #expect(mode.phase == .applying(a.id))
    #expect(mode.issuesChanged([b, c], checked: true) == [])          // the pipeline dropped the accepted issue
    #expect(mode.finished(.replaced) == [.wait(a.id, .seconds(6))])
    #expect(mode.phase == .awaiting(a.id) && mode.holdsKeys)
    for key in [ReviewMode.Key.next, .previous, .accept, .dismiss] { #expect(mode.key(key, issues: [], writes: true) == []) }
    #expect(mode.edited() == [])                                      // Skald's own write
    #expect(mode.issuesChanged([], checked: false) == [])             // suspended while the field is read again
    #expect(mode.issuesChanged([b.moved(to: 21), c.moved(to: 32)], checked: true) == [.show(b.id)])
    #expect(mode.phase == .showing(b.id) && mode.position == 21)
    #expect(mode.waitEnded(a.id) == [])                               // the wait is over already
}

@Test func theRecheckFindingNothingEndsTheModeAndAnEarlierIssueIsShownWhenNoneFollows() {
    var last = open([a])
    _ = last.key(.accept, issues: [a], writes: true)
    _ = last.finished(.replaced)
    #expect(last.issuesChanged([], checked: true) == [.close])
    var back = open([a, b])
    _ = back.key(.next, issues: [a, b], writes: true)
    _ = back.key(.accept, issues: [a, b], writes: true)
    _ = back.finished(.replaced)
    #expect(back.issuesChanged([a], checked: true) == [.show(a.id)])
}

@Test func aRecheckThatNeverArrivesEndsTheModeAfterTheWait() {
    var mode = open([a, b])
    _ = mode.key(.accept, issues: [a, b], writes: true)
    _ = mode.finished(.replaced)
    #expect(mode.waitEnded(b.id) == [])
    #expect(mode.waitEnded(a.id) == [.close])
    #expect(!mode.holdsKeys)
}

@Test(arguments: [ReplaceOutcome.failed, .refusedChanged, .refusedOtherField, .unsupported, .clipboardBusy, .unconfirmed])
func aWriteThatIsNotConfirmedEndsTheMode(_ outcome: ReplaceOutcome) {
    var mode = open([a, b])
    _ = mode.key(.accept, issues: [a, b], writes: true)
    #expect(mode.finished(outcome) == [.close])
    #expect(!mode.holdsKeys)
}

@Test func escLeavesWhileAWriteIsAppliedAndWhileTheRecheckIsAwaited() {
    var applying = open([a])
    _ = applying.key(.accept, issues: [a], writes: true)
    #expect(applying.key(.leave, issues: [], writes: true) == [.close])
    #expect(applying.finished(.replaced) == [])
    var awaiting = open([a])
    _ = awaiting.key(.accept, issues: [a], writes: true)
    _ = awaiting.finished(.replaced)
    #expect(awaiting.key(.leave, issues: [], writes: true) == [.close])
    #expect(awaiting.issuesChanged([b], checked: true) == [])
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
    #expect(mode.issuesChanged([a, c], checked: true) == [.show(c.id)])
    #expect(mode.issuesChanged([a], checked: true) == [.show(a.id)])
    #expect(mode.issuesChanged([], checked: false) == [.close])
}

@Test func theShownIssueMovingMovesThePositionWithIt() {
    var mode = open([a, b])
    #expect(mode.issuesChanged([a.moved(to: 9), b], checked: true) == [])
    #expect(mode.position == 9)
}

@Test func anEditWhileACardIsShownLeaves() {
    var mode = open([a, b])
    #expect(mode.edited() == [.close])
    #expect(!mode.holdsKeys)
}

@Test func everyWayOutClosesTheMode() {
    for leave: (inout ReviewMode) -> [ReviewMode.Effect] in [
        { $0.left() }, { $0.toggle(issues: [a]) }, { $0.key(.leave, issues: [a], writes: true) },
        { $0.issuesChanged([], checked: true) }, { $0.edited() },
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

**Per-task review** (Tasks 8, 9, 11 and 13 use it).

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
      static func rgb(_ category: IssueCategory) -> RGB              // the "Values" table; one palette for both appearances
      static func color(_ category: IssueCategory) -> NSColor
      static func isDotted(_ category: IssueCategory) -> Bool        // punctuation only
  }
  UnderlineView.Mark(rect: CGRect, category: IssueCategory)          // replaces `source`
  struct LegendView: View                                            // three rows: a 2 pt sample line in the colour (dotted for Punctuation) and the title
  enum BadgeContent: Equatable { case count(Int), tick }
  BadgePanel.show(_ content: BadgeContent, label: String, at frame: CGRect)
  /// What the badge shows after a snapshot: nil hides it.
  static func BadgeContent.next(current: BadgeContent?, issues: Int, checked: Bool, sameField: Bool, paused: Bool) -> BadgeContent?
  static func OverlayGeometry.badgeLabel(_ issues: [Issue]) -> String
  ```
- `badgeLabel`: `"No suggestions"`; `"1 suggestion: 1 spelling"`; `"3 suggestions: 2 spelling, 1 grammar"` (categories in `IssueCategory.allCases` order, zero counts left out, lowercase titles).
- `BadgeContent.next`: `.count(n)` for n > 0; `.tick` for zero issues when `checked`; for zero issues unchecked, `current` when `sameField` and not `paused`, else nil.
- The controller: `drawMarks` no longer returns early on an empty list. With a field, the field's frame and `.fieldFrame`, the badge shows what `next` says (paused is `settings.settings.pausedUntil` in the future), beside underlines too. Underlines are drawn model issues first, as today, each in its category's colour. A click on the tick does nothing.

- [ ] **Step 1: Write the failing tests.**

```swift
// CategoryPaletteTests
/// Machado, Oliveira and Fernandes (2009), severity 1.0, applied in linear RGB; the distance is Euclidean in sRGB.
@Test func everyPairStaysApartUnderEachDeficiency() {
    for matrix in [Simulation.none, .protanopia, .deuteranopia, .tritanopia] {
        for (a, b) in [(IssueCategory.spelling, .grammar), (.spelling, .punctuation), (.grammar, .punctuation)] {
            #expect(matrix.distance(CategoryPalette.rgb(a), CategoryPalette.rgb(b)) >= 0.35)
        }
    }
}

@Test func everyColourReadsOnALightAndOnADarkBackground() {     // WCAG contrast ratio
    for category in IssueCategory.allCases {
        #expect(contrast(CategoryPalette.rgb(category), .init(hex: 0xFFFFFF)) >= 3.2)
        #expect(contrast(CategoryPalette.rgb(category), .init(hex: 0x1E1E1E)) >= 3.2)
    }
    #expect(IssueCategory.allCases.filter(CategoryPalette.isDotted) == [.punctuation])
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
@Test func theBadgeKeepsItsContentWhileTheSameFieldIsRechecked() {
    #expect(BadgeContent.next(current: nil, issues: 3, checked: true, sameField: false, paused: false) == .count(3))
    #expect(BadgeContent.next(current: .count(3), issues: 0, checked: true, sameField: true, paused: false) == .tick)
    #expect(BadgeContent.next(current: .count(3), issues: 0, checked: false, sameField: true, paused: false) == .count(3))
    #expect(BadgeContent.next(current: .tick, issues: 0, checked: false, sameField: true, paused: false) == .tick)
    #expect(BadgeContent.next(current: .count(3), issues: 0, checked: false, sameField: false, paused: false) == nil)
    #expect(BadgeContent.next(current: .count(3), issues: 0, checked: false, sameField: true, paused: true) == nil)
    #expect(BadgeContent.next(current: nil, issues: 0, checked: false, sameField: true, paused: false) == nil)
}

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

**Per-task review** (Task 11 uses it).

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
  static func label(for issue: Issue) -> String   // the same text without a card; Task 11 announces it
  var reviewing: Bool                             // set by the controller; the card then shows its key line
  static let reviewKeys = "↩ accept   ⌫ dismiss   ← → move   esc leave"
  func accept(alternative: Int? = nil) async
  func dismiss()
  func addToDictionary()
  func hide()                                     // calls actions.hide(kind), then closes
  ```
- The view, top to bottom: the headline with a dot in the category's colour, and "Claude" at the right when Claude found it; the change in context (as today); one button per alternative (its text; a click accepts it); `Accept` (prominent) or, without a clean write, `Copy fix`; `Dismiss`; a `⋯` menu (`Menu` with `.menuIndicator(.hidden)`; it must not activate Skald, which the final live step checks) holding the hide item when `hideTitle` is set, the dictionary item when `dictionaryTitle` is set, and "Copy fix" when the fix has text. In review, `reviewKeys` as a caption under the buttons while the card is ready. The working, finished and notice phases stay as they are.
- Accessibility: every control's label ends with the card's `label`: "Accept: Grammar: word, change to wordt", "Dismiss: …", "More: …", and for an alternative "Use ‹guess›: …". The headline and change are one element labelled `label`. The list is a list of those.
- The controller: `hide` goes to `settings.hide(kind)`; the pipeline's republish removes every issue of that kind, which closes their cards through `retain`.

- [ ] **Step 1: Write the failing tests** in `CardOutcomeTests` (the suite's `issue(in:revised:…)` fixture, with `kind:` and `alternatives:`; `card(_:accept:hide:)` builds a model with recording actions, and `spelling(guesses:)` is a spelling issue on "teh end" whose first guess is its edit and the rest its alternatives):

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
- The controller: `drawMarks` splits into a read (`layout() async -> Layout?`: the marks, targets and badge for the current snapshot) and a show. A scroll event cancels a pending settle read, feeds `settle.scrolled(at:)` and executes the actions: `.hide` hides the underlines and closes a hover card that is only offering its choices (the badge and its count stay); `.read(after:)` sleeps on the injected clock, takes a layout and feeds its marks' rects to `settle.read`; `.show` shows that layout. A text change or a caret move redraws as today and calls `settle.redrawn()`. A snapshot or a window move while `settle.isHidden` updates the badge and the hover targets' absence only: no underline is shown; otherwise they redraw as today. A read that was started before a newer scroll event is dropped, not fed (a counter bumped by every scroll). The settle is made per focused field from `ScrollLag.ceiling(for: field.app)`. No read is ever scheduled except by these actions.
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

### Task 10: Hotkey tokens and the review keys

**Per-task review** (it holds keys system-wide; Task 11 uses it).

**Depends on:** Task 6 (`ReviewMode.Key`)

**Files:**
- Create: `Skald/Overlay/ReviewKeys.swift`
- Modify: `Skald/HotkeyCenter.swift`, `Skald/CompositionRoot.swift` (`registerPanelHotkey` keeps its token instead of `unregisterAll`)
- Test: `SkaldTests/ReviewKeysTests.swift`, `SkaldTests/Support/FakeRegistrar.swift`

**Interfaces:**
- Produces:
  ```swift
  struct HotkeyToken: Hashable
  protocol KeyRegistering: AnyObject {       // HotkeyCenter conforms
      /// nil: the system refused it. `released` is called when the key comes up.
      func register(_ h: Hotkey, action: @escaping @MainActor () -> Void, released: (@MainActor () -> Void)?) -> HotkeyToken?
      func unregister(_ token: HotkeyToken)
  }
  // HotkeyCenter also keeps `register(_:action:) -> HotkeyToken?` (released: nil) and `unregisterAll()` for stop().

  /// The six keys, held only between `hold` and `release`.
  final class ReviewKeys {
      static let bindings: [(key: ReviewMode.Key, hotkey: Hotkey)]   // → 124, ⇥ 48 → .next; ← 123 → .previous; ↩ 36 → .accept; ⌫ 51 → .dismiss; esc 53 → .leave; modifiers 0
      static let lingerLimit: Duration = .seconds(1)
      init(registrar: any KeyRegistering, sleep: @escaping (Duration) async throws -> Void)
      var isHolding: Bool
      /// All six or none: false, with nothing held, when any registration fails.
      func hold(_ pressed: @escaping @MainActor (ReviewMode.Key) -> Void) -> Bool
      /// Frees every key that is up at once; a key that is down stays registered, swallowed and without effect, until it comes up or `lingerLimit` passes.
      func release()
  }
  ```
- `HotkeyCenter` installs its one Carbon handler for both `kEventHotKeyPressed` and `kEventHotKeyReleased`. A hold started while keys from an earlier release still linger frees those first.

- [ ] **Step 1: Write the failing tests.** `FakeRegistrar` records registrations, refuses the key codes it is told to, and has `press(_:)` and `lift(_:)`; the tests' `sleep` is a gate they open by hand.

```swift
@Test func holdingRegistersTheSixKeysAndReleasingFreesThem() {
    #expect(keys.hold { _ in } && keys.isHolding)
    #expect(Set(registrar.held.map(\.keyCode)) == [124, 48, 123, 36, 51, 53])
    #expect(registrar.held.allSatisfy { $0.modifiers == 0 })
    keys.release()
    #expect(registrar.held.isEmpty && !keys.isHolding)
}

@Test func aKeyThatDoesNotRegisterHoldsNothing() {
    let registrar = FakeRegistrar(refusing: [36])
    #expect(!ReviewKeys(registrar: registrar, sleep: never).hold { _ in })
    #expect(registrar.held.isEmpty)
}

@Test func aPressReportsItsKey() {
    for code: UInt16 in [124, 48, 123, 36, 51, 53] { registrar.press(code); registrar.lift(code) }
    #expect(pressed == [.next, .next, .previous, .accept, .dismiss, .leave])
}

@Test func aKeyStillDownIsHeldUntilItIsReleased() {
    registrar.press(51)                       // ⌫ down: the dismiss that ends the mode
    keys.release()
    #expect(registrar.held.map(\.keyCode) == [51] && !keys.isHolding)
    registrar.press(51)                       // auto-repeat, if the system sends one: swallowed, no effect
    #expect(pressed == [.dismiss])
    registrar.lift(51)
    #expect(registrar.held.isEmpty)
}

@Test func aKeyNeverReportedUpIsFreedAfterTheLimit() async {
    registrar.press(36)
    keys.release()
    #expect(registrar.held.map(\.keyCode) == [36])
    await gate.open()                          // lingerLimit passes
    #expect(registrar.held.isEmpty)
}

@Test func holdingTwiceRegistersOnce()         // a second hold while holding returns true and adds nothing
```

- [ ] **Step 2: Run** the App suite; expected: FAIL to compile.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the App suite; expected: PASS.
- [ ] **Step 5: Commit** "Hold the review keys through hotkey tokens, and let go of a key only when it is up".

---

### Task 11: Review mode in the app

**Per-task review** (it decides when keys are held).

**Depends on:** Task 4 (`reviewHotkey`), Task 6 (`ReviewMode`), Task 8 (the card), Task 9 (the controller as it then is), Task 10 (`ReviewKeys`, `KeyRegistering`)

**Files:**
- Create: `Skald/Overlay/ReviewSession.swift`, `Skald/Overlay/Announcer.swift`
- Modify: `Skald/Overlay/OverlayController.swift`, `Skald/Overlay/IssueCard.swift` (`CardPanel.showStatus`), `Skald/CompositionRoot.swift` (the shortcut, the session's parts), `Skald/SettingsModel.swift` (`reviewHotkeyNote`), `Skald/Settings/GeneralPane.swift` (`HotkeyRecorder` made internal so Task 13's pane can use it)
- Test: `SkaldTests/ReviewSessionTests.swift`

**Interfaces:**
- Consumes: `ReviewMode` (Task 6); `ReviewKeys` (Task 10); `IssueCardModel.label(for:)`, `label`, `reviewing`, `copyFix()`, `accept(alternative:)`, `dismiss()` (Task 8).
- Produces:
  ```swift
  protocol Announcing { func announce(_ text: String) }
  struct VoiceOverAnnouncer: Announcing     // NSAccessibility.post(element: NSApp, notification: .announcementRequested, …) at high priority

  /// The mode, its keys and what its effects do, free of windows: the controller supplies `Actions`.
  final class ReviewSession {
      struct Actions {
          let issues: () -> [Issue]                      // the focused field's published list
          let writes: () -> Bool                         // the focused field's app has a clean write
          let show: (Issue, _ index: Int, _ count: Int) -> Void
          let accept: (UUID) async -> ReplaceOutcome     // through the shown card, so it says "Applying the fix…"
          let copy: (UUID) -> Void
          let dismiss: (UUID) -> Void
          let showChecking: () -> Void                   // the "Checking…" card
          let close: () -> Void                          // close cards that are ready, and the "Checking…" card
      }
      static let checking = "Checking…"
      init(keys: ReviewKeys, announcer: any Announcing, sleep: @escaping (Duration) async throws -> Void, actions: Actions)
      var isOpen: Bool
      func toggle()                                      // the shortcut
      func snapshot(_ issues: [Issue], checked: Bool, sameField: Bool)   // another field: left()
      func edited()
      func left()                                        // click elsewhere, pause, stop
      static func announcement(label: String, index: Int, count: Int) -> String   // "Grammar: word, change to wordt. 2 of 5"
  }
  CardPanel.showStatus(_ text: String, anchor: CGRect, screen: CGRect)   // one line, no controls
  OverlayController.toggleReview()
  SettingsModel.reviewHotkeyNote: String?
  ```
- The session executes `ReviewMode`'s effects. `toggle` opening: the keys are held first; if `hold` fails the mode is `left()` at once, nothing is shown and `Log.ui` says so. `.show` calls `show` and announces `announcement(…)` with the issue's place in the list; `.accept` awaits `accept` and feeds `finished`; `.wait(id, d)` calls `showChecking`, announces `checking`, and after `sleep(d)` feeds `waitEnded(id)`; `.close` releases the keys, cancels a pending wait and calls `close`.
- The controller: a review card is the issue's card alone, `reviewing`, anchored to its drawn word, else to its freshly read bounds, else to the badge, else to the field's frame. Pointer moves and scrolls don't close it, and a hover opens no card while the session is open. Snapshots, text changes, `clickedElsewhere`, a pause and `stop()` go to the session.
- The composition root registers `reviewHotkey` beside the panel's, each with its own token, re-registers the one that changed, and puts a refusal in `model.reviewHotkeyNote` (the panel note's wording).

- [ ] **Step 1: Write the failing tests** in `ReviewSessionTests`: a session on `FakeRegistrar`, a recording announcer, a gate for `sleep` and recording actions over a mutable issue list (`a`, `b` as in Task 6's tests, built with the app suite's issue fixture).

```swift
@Test func openingHoldsTheKeysShowsTheFirstIssueAndAnnouncesIt() {
    session.toggle()
    #expect(registrar.held.count == 6 && session.isOpen)
    #expect(shown == [a.id])
    #expect(announcer.said == ["Grammar: word, change to wordt. 1 of 2"])
}

@Test func theModeStaysClosedWhenTheKeysAreRefused() {
    // registrar refusing ↩ (36)
    session.toggle()
    #expect(!session.isOpen && registrar.held.isEmpty && shown.isEmpty && announcer.said.isEmpty)
}

@Test func anAcceptWaitsForTheRecheckThenShowsTheNextIssue() async {
    session.toggle()
    registrar.press(36); registrar.lift(36)
    await accepted()                                   // the accept action returned .replaced
    #expect(checkingShown == 1 && announcer.said.last == "Checking…" && registrar.held.count == 6)
    session.snapshot([], checked: false, sameField: true)
    #expect(session.isOpen)
    session.snapshot([b], checked: true, sameField: true)
    #expect(shown == [a.id, b.id])
}

@Test func theWaitRunningOutEndsTheModeAndFreesTheKeys() async {
    session.toggle(); registrar.press(36); registrar.lift(36); await accepted()
    await gate.open()                                  // recheckWait passes
    #expect(!session.isOpen && registrar.held.isEmpty && closed == 1)
}

@Test func noKeyIsHeldOnceTheModeIsClosed() async {
    for leave: (ReviewSession) -> Void in [
        { $0.toggle() }, { $0.snapshot([], checked: false, sameField: false) }, { $0.snapshot([], checked: true, sameField: true) },
        { $0.edited() }, { $0.left() },
    ] {
        // a fresh session, toggled open: registrar.held.count == 6
        leave(session)
        #expect(!session.isOpen && registrar.held.isEmpty)
    }
}

@Test func withoutACleanWriteReturnCopies() {
    // writes: false
    session.toggle(); registrar.press(36); registrar.lift(36)
    #expect(copied == [a.id] && session.isOpen)
}
```

- [ ] **Step 2: Run** the App suite; expected: FAIL to compile.
- [ ] **Step 3: Implement** the session, the announcer, `showStatus` and the wiring.
- [ ] **Step 4: Run** the App suite; expected: PASS.
- [ ] **Step 5: Commit** "Step through the issues from the keyboard".

---

### Task 12: The platform says when the frontmost app gives no focused element

**Per-task review** (Task 13 uses it).

**Depends on:** none

**Files:**
- Modify: `Packages/SkaldPlatform27/Sources/SkaldPlatform27/Access/FocusMachine.swift` (the machine, `FocusPort`, `FocusDriver`, the retries' end), `Access/FieldObserver.swift`, `Access/SystemTextAccess.swift`
- Test: the Platform suite that tests `FocusMachine` (`rg -l FocusMachine Packages/SkaldPlatform27/Tests`)

**Interfaces:**
- Produces:
  ```swift
  FocusMachine.Step.unreadable(String?)
  /// The frontmost observed app once its focus retries ran out without a focused element; nil once it gives one or another app is frontmost.
  SystemTextAccess.unreadableApp: AsyncStream<String?>
  ```
- The machine emits `.unreadable(app)` when the retries started for an activation end still `.missing` (a new input, `retriesEnded(generation:pid:)`, guarded like `retryTick`), and `.unreadable(nil)` with the next `.element` result or activation if it had said unreadable; never twice in a row with the same value. An app mid-launch whose element appears on a retry is never called unreadable.

- [ ] **Step 1: Write the failing tests** in the `FocusMachine` suite: an activation answered `.missing` yields no `.unreadable` step; `retriesEnded` for that generation yields `[.unreadable("com.example.app")]`; a later `.element` result includes `.unreadable(nil)`; `retriesEnded` for an older generation, or after another app activated, yields `[]`; an activation of another app after an unreadable one includes `.unreadable(nil)`.
- [ ] **Step 2: Run** the Platform suite filtered to that suite; expected: FAIL to compile.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the Platform suite; expected: PASS.
- [ ] **Step 5: Commit** "Report an app that gives no focused element".

---

### Task 13: The menu and Settings: two pauses, the legend, hidden kinds, the shortcut, and where Skald can't work

**Depends on:** Task 4 (`pause(for:)`, `hiddenKinds`, `reviewHotkey`), Task 7 (`LegendView`, `CategoryPalette`), Task 11 (`HotkeyRecorder`, `reviewHotkeyNote`), Task 12 (`unreadableApp`)

**Files:**
- Create: `Skald/Settings/SuggestionsPane.swift`
- Modify: `Skald/StatusItemController.swift`, `Skald/CompositionRoot.swift`, `Skald/Settings/SettingsWindow.swift`, `Skald/Overlay/OverlayController.swift` (reports the focused field's capabilities)
- Test: `SkaldTests/StatusTitleTests.swift`, `SkaldTests/StatusMenuTests.swift`

**Interfaces:**
- Consumes: `SystemTextAccess.unreadableApp` (Task 12).
- Produces:
  ```swift
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
- `menuLines`: paused or no Accessibility → `[title]`; using Claude → `[title, detail?, note?]`; every other state → `[note?, title]`; nils left out. `menuNeedsUpdate` adds these lines disabled, in order, in place of the heading and detail.
- The menu: "Pause for 30 Minutes" (`pause(30 * 60)`) and "Pause for an Hour" (`pause(60 * 60)`) where "Pause for an Hour" was; a submenu "Underline Colours" before "Settings…", its three items enabled without an action, each with a 10 pt dot image in `CategoryPalette.color` and the category's title.
- `SuggestionsPane` (tab "Suggestions", an existing SF Symbol): "Underlines" with `LegendView`; "Review" with the shortcut recorder on `reviewHotkey`, `reviewHotkeyNote`, and the line "Steps through the issues in the focused field: → or ⇥ next, ← previous, ↩ accept, ⌫ dismiss, esc to leave."; "Hidden suggestions" with one toggle per hidden kind (its title; off brings it back through `model.show`), or "Nothing is hidden." when there are none.
- The root keeps the last unreadable app and the last capabilities, and refreshes the status on each.

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

@Test func theNoteIsTheFirstLineUnlessARequestCanLeave() {
    #expect(StatusState.onThisMac.menuLines(note: .badgeOnly) == ["Issues are listed at the badge here", "Checking on this Mac"])
    #expect(StatusState.onThisMac.menuLines(note: nil) == ["Checking on this Mac"])
    #expect(StatusState.usingClaude([.nl], lastFailure: .unreachable).menuLines(note: .badgeOnly)
        == ["Dutch checks use Claude", "Last check failed: Claude unreachable", "Issues are listed at the badge here"])
    #expect(StatusState.claudeTrouble(.unreachable, fallbacks: []).menuLines(note: .badgeOnly)
        == ["Issues are listed at the badge here", "Claude unreachable"])
    #expect(StatusState.noAccessibility.menuLines(note: .cantRead) == ["Skald needs Accessibility access"])
    #expect(StatusState.paused(until: date).menuLines(note: .cantRead).count == 1)
}
```

  In `StatusMenuTests`: the menu holds "Pause for 30 Minutes" and "Pause for an Hour" when not paused and their actions pass 1800 and 3600; "Underline Colours" has a submenu titled "Spelling", "Punctuation", "Grammar".

- [ ] **Step 2: Run** the App suite; expected: FAIL to compile.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the App suite; expected: PASS.
- [ ] **Step 5: Commit** "Say in the menu where Skald can't work, and add the legend, two pauses and the Suggestions pane".

---

### Task 14: Changelog and documentation

**Depends on:** Tasks 1 to 13

**Files:**
- Modify: `CHANGELOG.md` (`## [Unreleased]`), `README.md` (the overlay's description, if it has one), `docs/superpowers/specs/2026-11-20-skald-upgrade-design.md` (under "Stage 2: overlay", a dated list "Decided in stage 2's plan, 2026-11-21": the rulings above and the measured ceilings, with the review-mode wait marked "pending Michael's confirmation"; the signed text above it is not rewritten), `AGENTS.md` (one line under Commands: the scroll probe's launch arguments)

- [ ] **Step 1: Write** the changelog entries. Added: three underline colours with a legend; the card's kind line, alternatives and "Hide suggestions like this"; the counter in every checked field; review mode with its shortcut and keys; the menu line where Skald can't work; VoiceOver labels; "Pause for 30 Minutes". Changed: "Ignore" is "Dismiss", "Never flag" is "Add to dictionary". Fixed: underlines drawn off the word after a scroll (they hide and come back; in an app Skald hasn't measured they stay hidden until the next edit or caret move).
- [ ] **Step 2: Run** `/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'`; expected: PASS (the changelog tool still parses the file).
- [ ] **Step 3: Commit** "Describe the overlay's categories, card, review mode and scroll handling".

---

## Final verification (controller, on the last commit)

1. `swift test --package-path Packages/SkaldCore`, `swift test --package-path Packages/SkaldPlatform27`, the App suite, the script tests; report each as passed/total.
2. Release build, then `scripts/verify-app build/dd.noindex/Build/Products/Release/Skald.app`.
3. Run it as its user will (the `run` skill): install the Release build over the backed-up `/Applications/Skald.app`, type the synthetic sample in TextEdit, and check that underlines show in three colours, the badge counts, the review shortcut opens a card, a ↩ while it is open does not reach TextEdit, esc frees the keys (a ↩ afterwards makes a new line), and opening the card's ⋯ menu leaves TextEdit the active app. Restore Michael's build. Record the commands and what they showed in the ledger.
4. The final whole-branch review (`sp-architect`), then the fix wave, then 1 and 2 again on the last commit.

## Memory, before and after (controller)

As stage 1's plan, with `build/baseline/Skald.app` (commit `d4c47fe`) against the new Release build: idle after 60 s, and after `open -a TextEdit build/memory-sample.txt` and 60 s. Four `footprint` figures, with the commits, go in the PR under "Memory".

## Owed (Michael)

- **Notes' scroll lag, and Zen's by hand:** with a Debug build installed and Skald quit, focus a long scratch note and run `open /Applications/Skald.app --args --probe-scroll --drive` (hands off for about ten minutes). For Zen, in a long textarea, run it without `--drive` and scroll 20 times each with the trackpad and with a flick, then quit Skald. The ceiling is in `~/Library/Application Support/com.michaelrigart.skald/probe/scroll-lag.json`. Until then Notes' underlines stay hidden after a scroll until the next edit or caret move. The same holds for any app the controller could not measure.
- **The spec's manual checks:** the three colours and the legend in light and dark mode; smooth trackpad scrolling in a Zen textarea, underlines never drawn off the word; review mode end to end in Notes, Zen and Slack; one pass with VoiceOver.
- **The rulings** above: confirm or overturn the review-mode wait (the one that changes the spec), and look over the rest.
