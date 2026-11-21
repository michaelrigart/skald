# Skald upgrade: Claude for Dutch and French, and a better overlay

**Date:** 2026-11-20
**Owner:** Michael Rigart
**Status:** In progress
**Sign-off:** Michael, 2026-11-21, with the three decisions as recorded under "Decisions".
**Builds on:** [Skald: design](2026-11-02-skald-design.md) (v1, branch `feat/skald-v1`, PR #1). Everything
v1 specifies stays as it is unless this document changes it.

## Why

Michael's words: "Just create a better version of Grammarly." He wants to stop using Grammarly as
soon as possible, on suggestion quality and on the interface, and "memory usage is an important
factor. I still need as much memory as possible for my other AI agent related work".

v1 can't replace Grammarly yet, for two reasons:

1. **Dutch and French are not good enough.** Apple's on-device model misses v1's bar in both, so
   v1 ships Dutch as spelling only and French with checking while typing off (`Eval/README.md`).
2. **The overlay is bare.** One underline colour per source, a card with the change and three
   buttons, no way to step through issues from the keyboard, and underlines that sit about 12 px
   off after a smooth scroll in Zen (acceptance run, 2026-11-16).

## Evidence

Held-out set, 20 paragraphs per language (7 clean), 14 to 17 reference edits per language. The data
is unreviewed, so every figure is provisional.

| Engine | en | nl | fr |
|---|---|---|---|
| Apple on-device, guard on (shipped) | P 1.00, R 1.00, pass | P 0.91, R 0.71, fail | P 0.87, R 0.81, fail |
| Claude Haiku 5.5, guard on (proxy) | P 1.00, R 1.00 | P 1.00, R 1.00 | P 1.00, R 0.94 |
| Claude Haiku 5.5, guard off (proxy) | P 1.00, R 1.00 | P 1.00, R 1.00 | P 1.00, R 1.00 |
| Claude Opus 5.5 (proxy) | same as Haiku in every cell | | |
| Claude Sonnet 5.5, guard on (proxy) | P 1.00, R 1.00 | P 1.00, R 1.00 | P 0.93, R 0.88, fail |

No clean paragraph was flagged in any Claude run.

- **The proxy run (2026-11-20)** was not an API run. Claude subagents proofread the 60 paragraphs
  with the app's check prompt (`Prompts.swift`) and without the answer key; their outputs were
  replayed through the app's cleaning, guard and scorer. One subagent saw all 60 paragraphs in one
  context, and no latency or cost was measured. A real API run is stage 1's gate.
- **Haiku's one miss with the guard on** is `fr-h07`, "Tout les tests" → "Tous les tests". The
  guard drops it as a borrowed word because "tout" is also an English word. This is a guard defect,
  already listed in `Eval/README.md` under "What missed".
- **Sonnet's failure** is `fr-h06`: "leurs équipe" → "leurs équipes", where the reference is "leur
  équipe".
- **Apple's cloud model** (`PrivateCloudComputeLanguageModel`) exists in the macOS 27.2 SDK, but all
  60 requests failed in an ad hoc signed binary; its documentation says it needs a managed
  entitlement.

## Goals

**Stage 1, engines.** The shortest path to Dutch and French he can use.

1. Dutch and French checks while typing go to Claude Haiku 5.5, once Michael turns that on.
   English stays on Apple's on-device model.
2. He can always see when text leaves the Mac, and say per app that it must not.
3. The guard no longer drops "Tout" → "Tous" and edits like it.

**Stage 2, overlay.** Independent of the engine.

4. Underlines in three colours by category, with a legend.
5. A card that says what kind of issue it is and why, offers alternatives, and can hide a kind of
   suggestion.
6. An issue counter in every checked field, and stepping through issues from the keyboard.
7. Underlines hide while the text scrolls and come back in the right place: always in the
   measured cases, best effort beyond them (see "Underlines and scrolling").
8. Skald says so when it can't work in an app, and the cards work with VoiceOver.

## Non-goals

- **Any new local process or model:** no LanguageTool server, no MLX model, no bundled
  dictionaries. Memory is the constraint (see Approaches).
- **Explanations written by a model.** The engine contract stays "the corrected text, nothing
  else": that is the contract the evidence was measured on, and a second output field costs
  latency and tokens. The card's "why" comes from Skald's own classification.
- **Style, tone and clarity suggestions while typing.** The panel's rewrites cover them on request.
- **English through Claude.** It passes on the Mac.
- **Changing the panel:** its engines, its default (`claude-opus-5-5` for Claude) and Fix stay as
  v1 has them, with one exception under "What is never sent".
- **Scrolls Skald can't see:** a dragged scrollbar, keyboard scrolling, a page that scrolls itself.
  No app notifies Skald of them and polling is ruled out; the hover check under "Underlines and
  scrolling" covers the card.
- **A spend cap or usage screen.** Stage 1 measures the cost; if it is not negligible this comes
  back to Michael.
- **v1's acceptance,** the review of the evaluation data, and a fresh held-out set to replace
  the cases that diagnosis has exposed. All three are still owed and none is this work.

## Anti-goals

v1's anti-goals stand. One changes, and four are added.

- **Changed:** v1 says Skald fails if it "sends text off the Mac unless the user chose a remote
  engine for that action or made one the panel's default". It becomes: Skald fails if it sends text
  off the Mac while typing unless the user turned on Claude checks, the language is one they chose
  for Claude, and the app is not kept on this Mac.
- Sends anything other than the paragraph being checked: no app name, no window title, no other
  paragraph, no identifier.
- Sends text while typing without the menu bar showing it.
- Falls back to a worse engine silently. When Claude can't be reached, the status says so.
- Leaves an underline in the wrong place. A hidden underline is better than a wrong one, so Skald
  hides them when the text moves and corrects one it finds misplaced; it can't promise an app never
  reports a stale position.

## Constraints

- v1's constraints stand: macOS 27, Swift 6, `SkaldCore` imports only Foundation and Observation,
  offsets in UTF-16 units, no user text in logs or on disk.
- **Memory.** The upgrade adds no process, no model and no word lists beyond a few hundred entries.
  The plan measures Skald's memory footprint before and after each stage and reports both numbers
  in the PR.
- **Measurement spend:** at most $5 of Claude API use in total, enforced by the eval tool's
  `--max-cost`.
- **Secrets.** The Claude key comes from the Keychain in the app and from the environment variable
  `SKALD_EVAL_CLAUDE_KEY` in the eval tool. It is never printed, logged or committed.
- **The held-out set only grades.** Nothing is tuned on it, including the guard fix.

## Approaches

**Chosen: Apple on-device for English, Claude Haiku 5.5 for Dutch and French.** It is the only
option measured to pass in Dutch and French, it costs no memory on the Mac, and the Claude client,
the Keychain key and the guard already exist. Its costs are privacy (Decision 1), a network round
trip per check, and a small API bill.

Ruled out:

| Option | Why not |
|---|---|
| LanguageTool, run locally | A Java server, typically 1 to 2 GB of memory. Never measured here (Java could not be installed for the bake-off). Dutch is its weakest of the three languages. |
| A local LLM through MLX | Runs on the GPU and takes several GB of memory, against v1's anti-goals and Michael's memory constraint. No published Dutch or French correction scores. |
| Apple's cloud model | Needs a managed entitlement; every request failed without it. Worth another look if Apple opens it. |
| DeepL Write, Textgears | No Dutch. |
| Foundation Models adapters | Dropped in OS 27, so Apple's model can't be tuned for Dutch or French. |
| Claude Sonnet 5.5 or Opus 5.5 | Sonnet failed French in the proxy. Opus scored the same as Haiku at 40 times the price. |
| Local spelling while typing, Claude only on a shortcut | Keeps typing private, but he would have to ask for every Dutch or French check, which Grammarly never makes him do. This is Decision 1's alternative. |

## Stage 1: engines

### The gate

The real API run gates stage 1's PR leaving draft. **Decided 2026-11-21 (Michael):** stage 1 is
built before the run, because no test key exists yet; the first draft of this spec put the run
first. The risk taken is that the build is wasted if Haiku misses the bar on the real API.

- Until the run, the typing request is sent with thinking disabled and without `fallbacks`; the
  run settles both as described below.
- The eval modes land in a commit of their own, before the guard fix. The gate run is made from
  that commit, so the fix still can't colour it.

The run:

- Bring the eval tool's two extra modes into the repository: `--mode claude --claude-model <id>
  --max-cost <dollars>` (one request per paragraph through `ClaudeEngine` and the app's check
  prompt, with tokens and cost recorded per request) and `--mode replay --outputs <file>`. A
  working draft of both is in `.superpowers/upgrade-evidence/eval-src/` (untracked), with the proxy
  outputs beside it.
- **Settle the request on the tuning part only** (the seed and `tuning.jsonl`). The model thinks by
  default; measure thinking on and off at low effort there and keep the faster one that meets the
  bar there. `ClaudeEngine` also sends `fallbacks: "default"`, which Haiku 5.5 does not offer; if
  the request is refused with it, the typing request drops the field.
- **Then grade the held-out set once** with that request, `claude-haiku-5-5`, guard on, and once
  more guard off for diagnosis. This run uses the guard as it was before the fix.
- **Pass, per language, for Dutch and French on the held-out set, guard on:** precision at least
  0.95, at most one clean paragraph flagged, recall at least 0.90 (v1's bar), and p90 latency under
  2 s. v1's 1 s is relaxed for this path: the check starts only after a pause, and Dutch spelling
  underlines still appear at once.
- The run reports the cost per check and a monthly figure at 500 checks a day.
- **Stop and bring it to Michael** if a language misses the bar, if p90 is 2 s or more, or if the
  monthly figure is above $5.

### Routing

- Settings gain one switch, off as shipped: **Check Dutch and French with Claude while typing.**
  Beside it, the two languages can be ticked separately, and the text says what is sent and to
  whom. Turning it on needs a stored Claude key.
- With the switch on, a ticked language's paragraph at the caret is checked by Claude instead of
  Apple's model. v1's per-language "model checks" and "checking while typing" switches now
  describe the on-device path only: they are not read for a language routed to Claude, are never
  rewritten by the Claude switch, and apply again whenever that language is back on the Mac (the
  switch off, a "This Mac only" app, Claude not answering). Settings labels them so.
- **Spelling beside Claude** follows those on-device switches too. As shipped, Dutch shows
  spelling flags at once and in the rest of the field, and Claude's answer withdraws the ones it
  left alone, as in v1. French shows no spelling flags (they miss v1's precision bar), so a French
  paragraph shows nothing until Claude answers and only the caret's paragraph is checked.
- The request: model `claude-haiku-5-5` (a setting of its own, separate from the panel's model),
  low effort, the existing check prompt unchanged, one request at a time, cancelled by a newer
  pause, with a timeout (builder's value, starting at 5 s).
- The answer goes through the same cleaning, diff and guard as Apple's. The guard's yes-or-no
  confirmation stays on Apple's on-device model.
- Paragraphs away from the caret keep getting spelling only, as in v1. So the only text sent is the
  paragraph he is typing in or has put the caret in.
- **English never goes to Claude,** and nothing does while Skald is paused.

### What is never sent

- Secure text fields and excluded apps. v1 never reads them, so there is nothing to send.
- Apps kept on this Mac: the per-app setting becomes three-way, **On / This Mac only / Off**. In a
  "This Mac only" app, Dutch and French fall back as under "When Claude can't answer". The panel
  honours it too: opened in such an app, it offers This Mac only and says why.
- Anything but the paragraph's text and the fixed instruction.

### Showing it

- The menu bar glyph has a second form, with a small cloud mark. It shows whenever the focused
  field's language and app mean its checks go to Claude, and not otherwise.
- The menu's first line says which it is: "Dutch and French checks use Claude" or "Checking on
  this Mac". Below it, one item keeps the frontmost app on this Mac.
- A card for an issue Claude found carries a small "Claude" label.
- **Added in review, 2026-11-21:**
  - While a request can leave, the first line is the Claude line, and a failed check shows as a
    second line under it ("Last check failed: Claude unreachable"). The line that names the
    fallback shows only while Claude checks are suspended.
  - The menu's "Turn On for ‹App›" sets an app to This Mac only when it is off by default or the
    Claude switch is on; unticking "Keep ‹App› on This Mac" is the step that lets it use Claude.
  - Removing the key turns the Claude switch off, and storing a key never turns it on.
  - The request log has one line for each request that was sent, with its outcome.

### When Claude can't answer

Offline, a timeout, a rejected key, a rate limit or a refusal:

- The language falls back to what its on-device switches say. As shipped that is spelling only
  for Dutch and no checks while typing for French, v1's measured defaults; Apple's model misses
  the precision bar in both. If he turned Apple's model on for a language himself, that is the
  fallback.
- Issues already shown stay while their text is unchanged; only new checks fall back.
- The status item says why ("Claude unreachable: Dutch is spelling only").
- A failed request is not retried for the same text. Repeated failures suspend Claude checks for
  an interval that grows to a cap (builder's values, on the injected clock); the next success
  clears it.

### The guard fix

- **Defect:** a French or Dutch word that happens to be an English word too ("tout", "plus")
  is treated as a borrowed English word, so correcting it to another native word is dropped.
- **Outcome:** a word the paragraph's own dictionary accepts is not a borrowed word just because
  the English dictionary accepts it too. New rows for the outcome table, all synthetic:

  | Proposed edit | Context | Outcome |
  |---|---|---|
  | "Tout" → "Tous" | "Tout les serveurs sont à jour" | keep |
  | "mergé" → "fusionné" | "J'ai mergé le correctif" | drop (unchanged) |
  | "gemerged" → "gemerkt" | "de fix … gemerged" | drop (unchanged) |

  The builder adds a Dutch keep row of the same shape and any row review turns up. Every existing
  row keeps its keep, drop or undecided outcome. A word borrowed through an English stem
  ("gemerged", "mergé") stays borrowed even where the native dictionary accepts it.
- **Narrowed in review, 2026-11-21:** the outcome holds only when the edit replaces the word
  one-for-one with a close native form of itself ("Tout" → "Tous", "warm" → "warme"). Translating
  a loanword the native dictionary accepts ("weekend" → "fin de semaine", "deadline" → "uiterste
  datum") stays dropped, as v1 requires; both are rows.
- The mechanism is the builder's. It is found by review with synthetic cases, then both sets are
  graded once more; a held-out result never feeds back into the rule.
- **`fr-h07` is an exposed case:** the defect was found on it, so its result after the fix proves
  nothing. The re-grade reports French with and without it, and stage 1's gate is the run made
  with the guard as it was before the fix. The cases listed under "What missed" in `Eval/README.md` are exposed in the same
  way; a fresh held-out set is owed with the data review (see Non-goals).

### Stage 1 verification

- Unit tests with exact values: routing (the switch off, each language, a "This Mac only" app for
  typing and for the panel, paused, key missing, English always local, the on-device switches
  ignored and left untouched for a routed language); the fallbacks and the failure backoff on the injected
  clock; the new guard rows; settings round-trips, including a v1 file read without loss.
- A test that the request body holds the paragraph and the instruction and nothing else.
- The API run's results go into `Eval/README.md`, beside Apple's, when the run is made.
- Manual, by Michael: type Dutch and French in Notes, Zen and Slack with the switch on; the glyph
  changes; a "This Mac only" app and a secure field send nothing (checked in the log, which counts
  requests and never holds text); with the network off, the status says why.

## Stage 2: overlay

Harper Desktop (open source, a separate always-on-top highlighter reading through Accessibility) is
the closest prior art; the builder reads its overlay code before changing ours.

### Categories

Every issue gets a category, decided by Skald from the edit, never by the model:

| Category | An edit is this when | Why line on the card |
|---|---|---|
| Spelling | the original word is a misspelling, or only accents or capitals change | "Spelling", or "Capital letter", "Accent" |
| Punctuation | only punctuation or spacing changes | "Punctuation" |
| Grammar | anything else the guard kept | "Grammar", or a finer kind where Skald can tell: "Repeated word", "Verb form" |

- The three categories are fixed. Finer kinds are the builder's, each with a test; a kind Skald
  can't decide surely stays at its category's name.
- Three underline colours, one per category, chosen by the builder to be told apart in light and
  dark mode and by the common colour-vision deficiencies. A legend sits in the menu and in
  Settings.

### The card

```
┌──────────────────────────────────────────┐
│ Grammar · Verb form              Claude  │
│ de back-up  word → wordt  elke nacht     │
│ [ Accept ]  [ Dismiss ]            [ ⋯ ] │
└──────────────────────────────────────────┘
  ⋯  Hide "Verb form" suggestions
     Add "word" to dictionary
     Copy fix
```

- Headline: the category and kind. Then the change in context, old → new.
- **Alternatives:** a spelling issue lists up to three of the spell checker's guesses, each one
  click to accept. A model issue has one fix.
- **Dismiss** replaces v1's Ignore. **Add to dictionary** replaces "Never flag" and still writes
  the never-touch list.
- **Hide suggestions like this** turns that kind off everywhere, at once, and Settings lists the
  hidden kinds with a switch to bring each back. It is offered for Punctuation and for the finer
  kinds only: a card that says just "Spelling" or "Grammar" doesn't offer it, because that would
  switch off most of what Skald finds.
- Where the app has no clean write, Accept is Copy, as in v1. The card still never takes keyboard
  focus.

### Counter and stepping through

- The badge with the issue count shows at the corner of every checked field, not only where range
  bounds are missing. Zero issues shows a quiet tick. A click opens the list of cards, as it does
  today.
- **Review mode,** started by a global shortcut (builder's default, changeable in Settings): the
  first issue's card opens. While it is open, and only then, Skald holds these keys: → or ⇥ next,
  ← previous, ↩ accept, ⌫ dismiss, esc leave. An edit to the field that isn't Skald's own, a focus
  change or a click elsewhere also leaves it. Outside review mode Skald holds none of these keys.
- The mode keeps a position in the text, not a list. Next and previous pick the nearest issue
  after or before it in the issues as they are then. While an accept is being applied the card
  says so and only esc is taken; when the write is confirmed the mode moves to the next issue
  after that position, and it ends when none is left. The wait is v1's write (in a paste-write
  app, its quiet period) and is accepted.
- This revisits v1's decision of 2026-11-06 that a card has no ↩ shortcut. That decision was about
  a card opened by hover while he types; here he asked for the mode with a shortcut.

### Underlines and scrolling

- On a scroll event the underlines and any hover card hide at once.
- **Measure first.** Accessibility gives no event for "the scroll has finished", and an app can
  answer with the same stale bounds twice before it catches up, so two equal reads prove nothing
  by themselves. Stage 2's first task extends the probe: in Notes, TextEdit and Zen's text areas,
  after wheel, trackpad and momentum scrolls, it samples a word's bounds until they stop changing
  and records how long each app lags behind the screen and whether that lag has a ceiling.
- **Where the lag has a ceiling,** underlines come back once reads agree across a span of twice
  that app's measured ceiling, counted from the last scroll event. A few more reads follow inside
  a fixed bound; one that differs hides the underlines and starts over.
- **This is best effort, and the spec says so.** A measured ceiling is not a guarantee: under
  heavier load an app can lag longer, and an underline can then show in the old place until a
  later read corrects it. The alternative that never shows a stale place is to keep underlines
  hidden after every scroll until the next edit, which would make them vanish each time he
  scrolls to read; that is the worse product.
- **Where it has none,** or the app wasn't measured, underlines stay hidden after a scroll until
  the next text or caret change redraws them, and the badge carries the count meanwhile.
- This is a deliberate exception to v1's rule that a timeout never lets things settle: there is
  no event to wait for. The span is measured per app, not guessed.
- This covers wheel and trackpad scrolls, the ones Skald gets an event for. For the rest, a hover
  reads the word's bounds again before its card opens; if they moved, Skald redraws instead of
  opening the card. This is best effort: it catches a word that has moved, not an app that still
  reports the old place.
- No polling is added, and no app gets `AXEnhancedUserInterface` that doesn't already.

### Pausing and unsupported apps

- The menu's pause becomes "Pause for 30 minutes" and "Pause for an hour". Per-app control is the
  three-way setting from stage 1.
- When the focused field is in an app Skald can't read, or can read but not mark, the menu's first
  line says which ("Skald can't read text in this app", "Issues are listed at the badge here").

### VoiceOver

- The badge, the list and every card control have accessibility labels that include the category
  and the change ("Grammar: word, change to wordt").
- Each step in review mode is announced.

### Stage 2 verification

- Unit tests with exact values: the category and kind of every row in the guard's outcome table;
  the hidden-kind filter; the review mode's state machine (keys, the ways out, an accept that keeps
  it open, no keys held outside it); the hover check; the scroll rule as pure logic on an injected clock (hide on scroll; equal reads
  inside the span don't show; equal reads across the span show; a differing read after showing
  hides again and starts over; an unmeasured app stays hidden).
- Manual, by Michael: the three colours and the legend in light and dark mode; smooth trackpad
  scrolling in a Zen textarea, underlines never drawn off the word; review mode end to end in
  Notes (Accessibility write), Zen (paste write) and Slack (badge list); one pass with VoiceOver.

### Decided in stage 2's plan, 2026-11-21

Pending Michael's confirmation (this changes the spec):

- Review mode waits for Skald's recheck after an accept. Skald's own write hides the field's issues
  until the paragraph is checked again, so "moves to the next issue when the write is confirmed"
  has nothing to move to. A "Checking…" card shows, the keys stay held (only esc acts), and the
  mode goes on at the first checked result that follows the recheck's start (at once if the
  recheck already finished before a paste write was confirmed), or ends after 6 s. Alternative:
  carry the paragraph's other issues across Skald's own write.
- The wait after an accept ends at the first checked result, even when Claude's answer for that
  paragraph is still on its way.
- While a write is applied or the recheck awaited, edits count as Skald's own: typing during
  "Checking…" doesn't leave the mode, and the keys pressed then are swallowed.

Inside the spec:

- While a request can leave, stage 1's "… checks use Claude" line stays first in the menu and the
  "can't work here" line follows it; otherwise that line comes first.
- A third menu line, "Skald can't show issues in this app", is for an app that gives text but
  neither positions nor a frame. "Skald can't read text in this app" is said only once Skald's
  focus retries ran out and the app has a window.
- "Only esc is taken" while a write is applied means only esc acts; the other keys stay held so
  they can't reach the app mid-write. A key still down when the mode ends stays held until it
  comes up (at most 1 s), and a held key acts once, not on every repeat.
- After an accept or a dismiss with no issue after the position, the mode goes to the last one
  before it.
- Punctuation is "only punctuation or spacing changes", measured on the words joined together: an
  apostrophe or a space inside a word counts ("Lets" to "Let's", "fallback" to "fall back", "it's"
  to "its").
- One colour palette serves both appearances (Spelling #D55E00, Grammar #0072B2, Punctuation
  #8B5CF6, Punctuation also dotted), because the text under an underline follows the page, not the
  system appearance. Every pair stays apart under the three common colour-vision deficiencies and
  each reads at 3.2:1 or more on white and on #1E1E1E.
- Every scroll event counts, whatever window it happens in.
- The badge keeps its last count while the same field is rechecked, and a field counts as checked
  once the paragraph holding the caret has a result.
- After a scroll, at most 20 position reads follow, and underlines come back only when their three
  confirming reads still fit within those 20.
- Where Skald has no clean write, each of the spell checker's other guesses is offered as Copy.
- Measured scroll lags: none yet. The probe (`--probe-scroll`) is built; until Michael runs it for
  Notes, TextEdit and Zen, every app keeps underlines hidden after a scroll until the next edit or
  caret move.

## Delivery

- **Two stages, each with its own plan and its own draft PR.** Stage 1 first: it is small (a
  routing rule, a switch, an indicator, one guard rule) and it is what makes Dutch and French
  usable. Stage 2 is the larger one and doesn't block daily use.
- Stage 1 is built on `feat/skald-upgrade`. Stage 2 gets its own branch, stacked on stage 1.
- User-visible changes get `CHANGELOG.md` entries under `## [Unreleased]`.

## Left to the builder

- All names, the code structure, and where the new settings sit in the storage format (within v1's
  versioning rule).
- Timeouts, the backoff intervals, the bound on the reads after underlines come back.
- The colours, the cloud mark, the tick, the card's exact layout, the review shortcut's default.
- The finer kinds beyond the three categories.
- The guard fix's mechanism.

## Decisions

Michael decided all three as recommended on 2026-11-21, and two more the same day:

- **The run after the build.** See "The gate". He has not yet made the test key, and Skald's
  Keychain holds no Claude key; no credential is read until he supplies one.
- **Reviews.** Codex was out of credits, so stage 1's plan, task and pre-merge reviews are cold
  Claude reviews. Codex reviewed this spec (approve, `xr-1795214803-8babbc30`) before the
  2026-11-21 changes.

1. **Privacy: may Dutch and French text go to Claude while he types?** v1 says no ("The Mac Studio
   or Claude for checking while typing" is a non-goal; "checking runs on his own hardware"). This
   spec says yes, behind a switch that ships off, for the caret's paragraph only, with the menu bar
   showing it and a per-app "This Mac only". The alternative is spelling only while typing and
   Claude on a shortcut. **Recommended: yes.** It is the only measured way to good Dutch and
   French without spending memory, and Grammarly already sends everything he types.
2. **The key for the API run.** **Recommended: a new, separate Claude API key** he can revoke
   afterwards, passed as `SKALD_EVAL_CLAUDE_KEY`. The alternative is Skald's own key from the
   Keychain. No key is read until he chooses.
3. **Order.** **Recommended: merge v1 (PR #1) first** and build this on top, so the upgrade's PRs
   stay small and reviewable. The alternative is to hold v1 until the upgrade is in, which makes
   one very large PR.

## Claude's calls, for Michael to check

- English stays on the Mac; Haiku rather than Sonnet or Opus.
- The Claude switch ships off, because the repository will be public.
- Only the caret's paragraph is sent; the rest of the field stays spelling only.
- When Claude can't answer, a language falls back to its on-device switches: as shipped, Dutch
  spelling only and French unchecked.
- v1's per-language switches describe the on-device path only and the Claude switch never rewrites
  them.
- French shows nothing until Claude answers, and only in the caret's paragraph.
- "This Mac only" also limits the panel in that app.
- Review mode stays open across its own accepts.
- Scrollbar drags and keyboard scrolls are covered only by the hover check.
- After a scroll, underlines wait out twice the lag measured per app, an exception to v1's "a
  timeout never lets things settle". It is best effort: an app lagging longer than measured can
  show a stale underline until the next read. An unmeasured app keeps them hidden until the next
  edit.
- The request's settings are chosen on the tuning part; the held-out set is graded once, with the
  guard as it was before the fix.
- The latency bar for the Claude path is 2 s at p90, not v1's 1 s.
- Stop and ask if the projected cost is above $5 a month.
- The card's "why" comes from Skald's own categories, not from the model.
- Review mode holds ↩, the arrows, ⇥, ⌫ and esc while it is open.
- "Hide suggestions like this" works per kind, applies everywhere, and isn't offered on a plain
  "Spelling" or "Grammar" card.
- The badge shows in every checked field.
- Two stages, stage 1 first.
