# Skald Upgrade, Stage 1 (Engines) Implementation Plan

**Status:** In progress

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. In this repository the `plan-run` skill runs plans and takes precedence over both.

**Goal:** Dutch and French checks while typing go to Claude Haiku 5.5 behind a switch that ships off, visibly and per app, with failures falling back to the on-device settings; the eval tool can measure that path; the guard stops dropping "Tout" → "Tous".

**Architecture:** `EngineRouter` gains a `.claude` typing route decided from the settings, the key and the app's three-way mode; v1's rules become `onDevice(_:)` and still decide spelling and every fallback. `CheckPipeline` sends the caret chunk to a Claude engine made per request from a factory (typing options, own model setting), races it against a 5 s deadline on the injected clock, runs the answer through the same `ModelAnswer.judge`, and keeps failures in a pure `ClaudeBackoff`. It publishes a `ClaudeStatus` stream the app turns into the cloud glyph and the menu's first line. The eval tool's two new modes reuse `ClaudeEngine` with the same typing options.

**Tech Stack:** Swift 6, Swift Testing, SwiftPM packages `SkaldCore` (Foundation and Observation only) and `SkaldPlatform27`, the AppKit/SwiftUI app target, xcodegen, `rsvg-convert` for the glyph.

**Spec:** `docs/superpowers/specs/2026-11-20-skald-upgrade-design.md`, "Stage 1: engines" and the sections it relies on (Goals, Non-goals, Anti-goals, Constraints, "Left to the builder", "Decisions"). v1's rules: `docs/superpowers/specs/2026-11-02-skald-design.md`. Stage 2 is out of scope.

**Base:** `feat/skald-upgrade` at `5665de7` (this plan), with `feat/skald-v1` through `c4c165a` merged at `6a3018e`.

**Order:** the tasks run serially, 1 to 12; each `Depends on:` names the task before it and any task whose interface it uses.

## Global Constraints

- macOS 27, Swift 6. `SkaldCore` imports only Foundation and Observation; OS-specific APIs and `#available` live in `SkaldPlatform27`; the app may use AppKit and SwiftUI.
- Text offsets are UTF-16 units (`TextRange`), never `Character` counts.
- No user text and no secret in logs, on disk or printed. The typing log counts requests and names outcomes, nothing else. The eval tool prints only the synthetic eval data and never the key.
- The key comes from the Keychain in the app (`KeychainStore.claudeKey`) and only from `SKALD_EVAL_CLAUDE_KEY` in the eval tool. **No task makes a real API call or reads a credential**: tests use `StubTransport` and fakes, and every eval command an implementer runs has the variable unset.
- Measurement spend: at most $5 of Claude API use in total, enforced by `--max-cost` (see "Owed").
- Only the caret paragraph's chunk and the fixed instruction leave the Mac: no app name, window title, other paragraph or identifier. English never goes to Claude, and nothing does while Skald is paused.
- The typing request: model `claude-haiku-5-5` (setting `claudeTypingModel`), effort low, the check prompt unchanged, **thinking disabled and no `fallbacks` field or beta header** until the gate run; both live only in `ClaudeRequestOptions.typing`.
- The panel's request stays byte for byte as v1 sends it (`ClaudeRequestOptions.panel`; the existing `requestShape` test passes unchanged).
- The held-out set only grades; nothing is tuned on it. Eval data is synthetic and holds no real company names.
- Every command below runs outside the agent sandbox, prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Every compiling `xcodebuild` passes a `-derivedDataPath` ending in `.noindex`.
- Suites, by what a task changed (implementers run only these; the controller runs everything at the end):
  - Core: `swift test --package-path Packages/SkaldCore`
  - Platform: `swift test --package-path Packages/SkaldPlatform27`
  - App: `mise exec -- xcodegen generate`, then `xcodebuild test -project Skald.xcodeproj -scheme Skald -derivedDataPath build/dd.noindex -quiet -only-testing:SkaldTests`
- Commits: imperative mood, no agent attribution, staged changes checked for secrets. A commit stages the task's listed files by path, never a directory.

## Values this plan decides (spec, "Left to the builder")

| Item | Decision |
|---|---|
| Timeout | `CheckPipeline.claudeTimeout = .seconds(5)`, on the injected clock; at the deadline the request is cancelled and a late answer ignored. |
| Backoff | Claude checks are suspended after 2 failures in a row: 30 s, then doubling (60, 120, 240) to a cap of 5 min (`ClaudeBackoff`). The next success clears the suspension and the trouble. A refusal or a cut-off answer (`.declined`) neither counts nor clears. |
| No retry for the same text | The last 32 failed texts (by hash, in memory) are not sent again; a changed paragraph is a new text. A new key clears them (`CheckPipeline.resetClaude()`). |
| Failure classes (`ClaudeTrouble`) | 401, 403 and a missing key → `keyRejected`; 429 → `rateLimited`; refusal, `max_tokens` → `declined`; timeout, offline, 5xx, anything else → `unreachable`; cancellation is no failure. `ClaudeEngine` maps 401/403 to `.unavailable(.claudeKeyRejected)` and 429 to `.unavailable(.claudeRateLimited)`. |
| Confirmation on the Claude path | Apple's on-device confirmer runs whenever Apple's model is available and not thermal-paused, whatever the language's on-device switches say (the measured runs confirm unconditionally; spec: the on-device switches are not read for a routed language). |
| Settings storage | `version` 2. `appOverrides` values become `"on"`, `"thisMacOnly"`, `"off"` (v1's `true`/`false` read as on/off; an unknown value drops that entry only). New keys `claudeTyping` (false), `claudeLanguages` (`{"nl": true, "fr": true}`), `claudeTypingModel` (`"claude-haiku-5-5"`). A v1 file is read and written back as version 2, so v1 opens it read-only instead of moving it aside. |
| Settings changes that recheck | `claudeTyping`, `claudeLanguages` and `appOverrides` join v1's `typingChecks`/`modelChecks` in `update(settings:)`'s recheck rule. |
| Names | `ClaudeRequestOptions`, `TypingRoute.claude`, `EngineRouter.onDevice(_:)`, `AppMode`, `ClaudeBackoff`, `ClaudeTrouble`, `ClaudeStatus`, `Issue.engine`, `UnavailableReason.claudeKeyRejected / .claudeRateLimited / .keptOnThisMac`. |
| Menu | First line "Checking on this Mac" (replaces "Skald is on") or "Dutch and French checks use Claude"; under it "Keep ‹App› on This Mac" (a checkmark item, shown when the frontmost app isn't Off). Glyph asset `SkaldMenuBarCloud`, from `design/menubar-cloud.svg`. |
| Panel in a kept app | Picker and default are This Mac only; a request for another engine is `.unavailable(engine, .keptOnThisMac, alternatives: [.thisMac])`. |
| Request log | `Log.claude`, one line per typing request: `typing request N: answered` or the trouble's name. |
| Eval | `--thinking on|off` and `--fallbacks on|off` (default off, i.e. `.typing`); `--out` required in claude mode; prices by exact model id; a request is refused unless spend so far plus its ceiling stays within `--max-cost`, and a sent request whose answer carries no usage (lost to a transport error or timeout) is charged its ceiling, so `--max-cost` is a strict bound; `--max-cost` above 0 and at most 5; latency bar 2 s for claude, none for replay; recall and clean paragraphs judged in every mode but spelling. |
| Guard fix | Narrowed in review (commit `bafd781`, spec "The guard fix"): a word the paragraph's dictionary accepts and English also has skips the borrowed check only when the edit replaces it one-for-one with a near-homophone native form; translations of a loanword stay dropped. Borrowing through an English stem ("gemerged", "mergé") is unchanged. Dutch keep row: "warm" → "warme". |
| Memory | `/usr/bin/footprint -p Skald`, idle and after a TextEdit check, baseline vs. new Release build; numbers go in the PR description. |

## Review Focus

1. **A request leaves while the menu bar shows no cloud** (the anti-goal "sends text while typing without the menu bar showing it"). Expected: the pipeline publishes `sending: true` before it calls the engine. Task 8, `theStatusSaysSendingBeforeTheRequestLeaves`.
2. **A v1 settings file saved back with its old `"version": 1` but three-way values**: v1 would then fail to decode it and move it aside as corrupt. Expected: written as version 2. Task 4, `aV1FileSavedAgainIsWrittenAsVersion2`.
3. **A pause or a "This Mac only" landing after the check started but before the send, or an answer arriving after the switch went off or the paragraph changed.** Expected: nothing sent in the first case, nothing published in the second. Task 7, `aPauseBeforeTheSendSendsNothing`, `keepingTheAppOnThisMacBeforeTheSendSendsNothing`, `anAnswerArrivingAfterTheSwitchWentOffIsDropped` and `aNewerPauseCancelsTheRunningRequest`; Task 8 keeps them passing with the status publish in place.
4. **A French paragraph's Claude issues wiped when the caret leaves and comes back**, because v1's spelling-off branch clears a whole key and French spelling is off. Expected: they stay. Task 7, `claudesFrenchIssuesSurviveTheCaretLeavingAndComingBack`.
5. **Real spend passing `--max-cost`**: a model id priced by substring ("claude-haiku-4-5" at a tenth of its price), or a request whose answer was lost and so never counted. Expected: only exact ids are priced; a lost answer costs its ceiling; the cap holds per request. Task 2, `pricesAreExactModelIDs`, `aRequestWhoseCeilingWouldPassTheLimitIsNeverSent` and `aLostAnswerIsChargedItsCeiling`.

---

## Baseline (controller, before Task 1)

Build the commit before Task 1 for the memory comparison; no commit.

```bash
mise exec -- xcodegen generate
xcodebuild -project Skald.xcodeproj -scheme Skald -configuration Release -derivedDataPath build/dd-baseline.noindex -quiet build
mkdir -p build/baseline && ditto build/dd-baseline.noindex/Build/Products/Release/Skald.app build/baseline/Skald.app
git rev-parse HEAD   # record this SHA as the baseline's commit
```

Measuring happens after the final verification ("Memory, before and after").

---

### Task 1: Typing request options and Claude's failure reasons

**Safety boundary: what is sent off the Mac. Per-task review.**

**Depends on:** none

**Files:**
- Create: `Packages/SkaldCore/Sources/SkaldCore/Engines/Remote/ClaudeRequestOptions.swift`
- Modify: `Packages/SkaldCore/Sources/SkaldCore/Engines/Remote/ClaudeEngine.swift` (init, `Body`, status mapping, `maxTokens`)
- Modify: `Packages/SkaldCore/Sources/SkaldCore/Engines/Remote/HTTPTransport.swift:26-39` (`body(of:mapping:status:)`)
- Modify: `Packages/SkaldCore/Sources/SkaldCore/Engines/Engine.swift:27-30`
- Modify: `Skald/CompositionRoot.swift:145` (`options: .panel`), `Skald/StatusItemController.swift:44-58` (explanations)
- Test: `Packages/SkaldCore/Tests/SkaldCoreTests/ClaudeEngineTests.swift`, `SkaldTests/StatusTitleTests.swift`

**Interfaces:**
- Produces:
  ```swift
  /// What a Claude request asks beyond the model and the text. `.typing` is provisional until the gate run
  /// settles it (spec 2026-11-20, "The gate"); this is the one place to change it.
  public struct ClaudeRequestOptions: Equatable, Sendable {
      public enum Thinking: Equatable, Sendable { case modelDefault, disabled }
      public var thinking: Thinking
      public var serverFallbacks: Bool
      public init(thinking: Thinking, serverFallbacks: Bool)
      public static let panel = ClaudeRequestOptions(thinking: .modelDefault, serverFallbacks: true)
      public static let typing = ClaudeRequestOptions(thinking: .disabled, serverFallbacks: false)
  }
  ClaudeEngine.init(model: String, apiKey: @escaping @Sendable () -> String?, transport: any HTTPTransport, options: ClaudeRequestOptions)  // replaces v1's init; no default, so every caller chooses
  ClaudeEngine.maxTokens = 4096   // public static, the body's max_tokens
  UnavailableReason: + claudeKeyRejected, claudeRateLimited
  ```
- `.disabled` adds `"thinking": {"type": "disabled"}`; `.modelDefault` sends no `thinking`. `serverFallbacks` adds `"fallbacks": "default"` and the `anthropic-beta: server-side-fallback-2026-07-01` header; without it, neither.
- Non-2xx: 401 and 403 → `.unavailable(.claudeKeyRejected)`, 429 → `.unavailable(.claudeRateLimited)`, any other → `.failed` (as before). `StudioEngine` keeps `.failed` for every status (the `status:` parameter defaults to `{ _ in .failed }`).

- [ ] **Step 1: Write the failing tests** in `ClaudeEngineTests` (the `engine(_:key:)` helper passes `options: .panel`; `requestShape` keeps every assertion as it is):

```swift
@Test("the typing request holds the paragraph and the check instruction, thinking disabled, and nothing else")
func typingRequestShape() async throws {
    let request = EngineRequest(action: .check, language: .nl, text: "Ik heb de fix nagekeken en het word morgen uitgerold.")
    let transport = StubTransport(json: reply(content: #"[{"type":"text","text":"Ik heb de fix nagekeken en het wordt morgen uitgerold."}]"#))
    _ = try await ClaudeEngine(model: "claude-haiku-5-5", apiKey: { "sk-test-key" }, transport: transport, options: .typing).run(request)
    let sent = try #require(await transport.requests.first)
    #expect(sent.allHTTPHeaderFields == ["x-api-key": "sk-test-key", "anthropic-version": "2026-10-21", "Content-Type": "application/json"])
    let decoded = try #require(try JSONSerialization.jsonObject(with: try #require(sent.httpBody)) as? NSDictionary)
    #expect(decoded == [
        "model": "claude-haiku-5-5",
        "max_tokens": 4096,
        "system": Prompts.instructions(.check, .nl),
        "messages": [["role": "user", "content": request.text]],
        "output_config": ["effort": "low"],
        "thinking": ["type": "disabled"],
    ] as NSDictionary)
}

@Test("a rejected key and a rate limit are named", arguments: [(401, UnavailableReason.claudeKeyRejected), (403, .claudeKeyRejected), (429, .claudeRateLimited)])
func namedHTTPErrors(_ example: (Int, UnavailableReason)) async {
    let transport = StubTransport(status: example.0, json: #"{"type":"error","error":{"type":"x","message":"y"}}"#)
    #expect(await failure(engine(transport)) == .unavailable(example.1))
}
```

Change `httpErrors`'s arguments to `[400, 500, 529]`. In `StatusTitleTests.everyReasonHasItsOwnFixedText`, add both reasons to the list.

- [ ] **Step 2: Run, expect failure**

Run: `swift test --package-path Packages/SkaldCore --filter ClaudeEngineTests`
Expected: compile failure (`options:` unknown).

- [ ] **Step 3: Implement** the options file, the init, the body fields and the status mapping in `ClaudeEngine`/`HTTPTransport`; pass `options: .panel` in `CompositionRoot.makeEngines`. Explanations: `.claudeKeyRejected` "Claude didn't accept the API key", `.claudeRateLimited` "Claude is limiting requests".

- [ ] **Step 4: Run, expect pass**

Run: the focused command, then the Core suite and the App suite.
Expected: all pass; `requestShape` unchanged and green.

- [ ] **Step 5: Commit**

```bash
git add Packages/SkaldCore/Sources/SkaldCore/Engines/Remote/ClaudeRequestOptions.swift \
  Packages/SkaldCore/Sources/SkaldCore/Engines/Remote/ClaudeEngine.swift \
  Packages/SkaldCore/Sources/SkaldCore/Engines/Remote/HTTPTransport.swift \
  Packages/SkaldCore/Sources/SkaldCore/Engines/Engine.swift \
  Packages/SkaldCore/Tests/SkaldCoreTests/ClaudeEngineTests.swift \
  Skald/CompositionRoot.swift Skald/StatusItemController.swift SkaldTests/StatusTitleTests.swift
git commit -m "Give Claude's typing request its own options and name a rejected key"
```

---

### Task 2: The eval tool's Claude and replay modes

**Safety boundary: the key and spend off the Mac. Per-task review. Lands in a commit of its own, before Task 3: the gate run is made from this commit.**

**Depends on:** Task 1 (the previous task; `ClaudeRequestOptions`, `ClaudeEngine.maxTokens`)

**Files:**
- Modify: `Packages/SkaldPlatform27/Sources/SkaldPlatform27/Eval/EvalRunner.swift` (modes, options, bar, replay, raw answers)
- Create: `Packages/SkaldPlatform27/Sources/SkaldPlatform27/Eval/ClaudeSpend.swift` (`ModelPrice`, `CostTrackingTransport`, `BudgetExceeded`)
- Create: `Packages/SkaldPlatform27/Sources/SkaldPlatform27/Eval/EvalInputs.swift` (`EvalReplay`, `EvalClaudeKey`)
- Modify: `Packages/SkaldPlatform27/Sources/skald-eval/main.swift`
- Move (`git mv`): `Packages/SkaldCore/Tests/SkaldCoreTests/Support/StubTransport.swift` → `Packages/SkaldCore/Sources/SkaldCoreTestSupport/StubTransport.swift` (public, plain `import SkaldCore`)
- Modify: `Packages/SkaldCore/Tests/SkaldCoreTests/ClaudeEngineTests.swift` and `Packages/SkaldCore/Tests/SkaldCoreTests/StudioEngineTests.swift` (add `import SkaldCoreTestSupport`; they are the only users of `StubTransport`)
- Modify: `Eval/README.md` ("Running")
- Test: `Packages/SkaldPlatform27/Tests/SkaldPlatform27Tests/EvalRunnerTests.swift` (options, bar, and the runner-path tests beside its private helpers); Create `Packages/SkaldPlatform27/Tests/SkaldPlatform27Tests/EvalClaudeTests.swift` (prices, spend, key, replay loading)

Port from the untracked draft in `.superpowers/upgrade-evidence/eval-src/`, with these differences: no `languagetool` or `apple-cloud` mode; prices by exact id; the cap refuses by ceiling, not after passing it, and charges a lost answer its ceiling; `--out` required for claude; raw answers written; latency bar by mode; the key read through `EvalClaudeKey`; `--thinking` and `--fallbacks`.

**Interfaces:**
- Consumes: `ClaudeEngine(model:apiKey:transport:options:)`, `ClaudeEngine.maxTokens`, `ClaudeRequestOptions` (Task 1).
- Produces:
  ```swift
  public enum EvalMode: String, Sendable { case model, spelling, claude, replay }
  EvalMode.isModelPath: Bool   // every mode but spelling; EvalBar.misses judges clean paragraphs and recall on it (today: `mode == .model`)
  public struct EvalOptions: Equatable, Sendable {      // existing four fields first, so v1 call sites compile
      public var set: String; public var mode: EvalMode; public var guardOn: Bool; public var out: String?
      public var claudeModel: String? = nil
      public var maxCost: Double? = nil
      public var claudeRequest: ClaudeRequestOptions = .typing
      public var outputs: String? = nil
  }
  EvalBar.maximumP90Ms(_ mode: EvalMode) -> Double?   // replaces the constant: model 1_000, claude 2_000, spelling nil, replay nil
  public struct EvalRun { ...; public var raw: [EvalOutput] }  // each case's cleaned engine answer, before the guard (model-path modes)
  EvalRunner.init(mode: EvalMode, guardOn: Bool, engine: any Engine = AppleEngine(), replay: [String: String]? = nil)  // public
  public struct ModelPrice: Equatable, Sendable {
      public let inputPerMTok: Double, outputPerMTok: Double
      public static func forModel(_ id: String) -> ModelPrice?   // exactly: claude-haiku-5-5 0.10/0.50, claude-sonnet-5-5 2/10, claude-opus-5-5 4/20
      public func cost(input: Int, output: Int) -> Double
  }
  public actor CostTrackingTransport: HTTPTransport {
      public init(inner: any HTTPTransport, price: ModelPrice, maxCost: Double, usageLog: URL?)
      public var spent: Double { get }
      public var summary: String { get }
  }
  public struct BudgetExceeded: Error {}
  public enum EvalReplay { public static func load(_ url: URL) throws -> [String: String] }  // id → output; null outputs and blank lines skipped
  public enum EvalClaudeKey {
      public static let variable = "SKALD_EVAL_CLAUDE_KEY"
      public static func read(from environment: [String: String]) throws(EvalUsageError) -> String
  }
  ```
- `--thinking on` → `.modelDefault`, `off` → `.disabled`; `--fallbacks on|off` → `serverFallbacks`.
- Cap rule: before forwarding, refuse with `BudgetExceeded` (the inner transport is not called) when `spent + price.cost(input: httpBody byte count, output: ClaudeEngine.maxTokens) > maxCost`. A token is at least one byte, and the body's JSON keys outweigh the API's few template tokens, so the ceiling bounds the request. A forwarded request is charged its answer's `usage.input_tokens`/`output_tokens` at the exact price; when there is no usage to read (the inner transport threw, the request timed out, or the body has no `usage`), it is charged its ceiling, so `spent` never understates the bill and `--max-cost` is a strict bound.
- Files in claude mode with `--out X`: `X` (graded outputs, as today), `X.raw.jsonl` (`EvalOutput` lines of `run.raw`, replayable), `X.usage.jsonl` (one `{"input_tokens":…,"output_tokens":…,"cost":…,"total_cost":…}` line per request). stderr gets `claude request: ` plus that line. After the run, `summary` is printed.
- Summary format: `claude usage: N requests, I input tokens, O output tokens, $T of $L; $C a check, $M a month at 500 checks a day` (`T` `%.4f`, `L` `%.2f`, `C` `%.6f`, `M` = C × 500 × 30, `%.2f`), plus `, stopped at the cost limit` when a request was refused. A request charged its ceiling counts in `N` and in the cost, adds no tokens, and its `usage.jsonl` line holds the ceiling as `cost` with null token counts; `aLostAnswerIsChargedItsCeiling` checks the summary line too.
- Order in `main.swift` for claude: options parsed (usage errors exit 2), cases loaded, key read (missing → exit 2 before any request).

- [ ] **Step 1: Write the failing tests**

`EvalRunnerTests` (extend):
```swift
@Test func parsesClaudeAndReplayOptions() throws {
    #expect(try EvalOptions.parse(["--set", "s.jsonl", "--mode", "claude", "--claude-model", "claude-haiku-5-5", "--max-cost", "1.5", "--out", "o.jsonl"])
        == EvalOptions(set: "s.jsonl", mode: .claude, guardOn: true, out: "o.jsonl", claudeModel: "claude-haiku-5-5", maxCost: 1.5, claudeRequest: .typing))
    #expect(try EvalOptions.parse(["--set", "s", "--mode", "claude", "--claude-model", "claude-haiku-5-5", "--max-cost", "1", "--out", "o", "--thinking", "on", "--fallbacks", "on"]).claudeRequest
        == ClaudeRequestOptions(thinking: .modelDefault, serverFallbacks: true))
    #expect(try EvalOptions.parse(["--set", "s", "--mode", "replay", "--outputs", "r.jsonl", "--guard", "off"])
        == EvalOptions(set: "s", mode: .replay, guardOn: false, out: nil, outputs: "r.jsonl"))
}
```
`usageErrors` arguments: replace the `--mode fast` message by `"--mode is model, spelling, claude or replay"` and add:

| Arguments (after `--set s`) | Message |
|---|---|
| `--mode claude --max-cost 1 --out o` | `--mode claude needs --claude-model` |
| `--mode claude --claude-model claude-haiku-4-5 --max-cost 1 --out o` | `no price for claude-haiku-4-5` |
| `--mode claude --claude-model claude-haiku-5-5 --out o` | `--mode claude needs --max-cost` |
| `--mode claude --claude-model claude-haiku-5-5 --max-cost 1` | `--mode claude needs --out, to keep the answers it pays for` |
| `--mode claude --claude-model claude-haiku-5-5 --max-cost 0 --out o` (and `5.01`, `x`) | `--max-cost is a dollar amount above 0 and at most 5` |
| `--mode claude … --thinking maybe` | `--thinking is on or off` |
| `--mode claude … --fallbacks yes` | `--fallbacks is on or off` |
| `--mode replay` | `--mode replay needs --outputs` |
| `--mode model --max-cost 1` | `--claude-model, --max-cost, --thinking and --fallbacks are for --mode claude` |
| `--mode model --outputs r` | `--outputs is for --mode replay` |

`EvalBarTests.latency`: add `#expect(EvalBar.misses(scored(tp: 20, latencies: fast + [1_999, 5_000, 9_000]), mode: .claude).isEmpty)`, `… [2_000, …] , mode: .claude) == [.latency]`, and `mode: .replay` with p90 9_000 → no latency miss.
`EvalBarTests.cleanParagraphs`: add `#expect(EvalBar.misses(scored(tp: 40, fp: 2), mode: .claude) == [.cleanParagraphs])` and the same for `.replay`.
`EvalBarTests.recall`: add `#expect(EvalBar.misses(scored(tp: 17, fn: 2), mode: .claude) == [.recall])` and the same for `.replay`.

Runner-path tests, in `EvalRunnerTests.swift` beside its private `MappedDetector`, `ScriptedSpelling`, `NoFacts` and `Approves` (they stay private: shared top-level test names clash across files):
```swift
@Test func aReplayedCaseWithoutARecordedAnswerIsARequestError() async
// runner(.replay, replay: ["a": answer]) on cases a and b (both .nl): a's output is the answer as cleaned,
// b's error == "failed"; EvalBar.verdict(score, errors: 1, mode: .replay) == .noVerdict(errors: 1)

@Test func claudeModeSendsEachCaseAsTheTypingRequestAndKeepsTheRawAnswer() async throws
// EvalRunner(mode: .claude, guardOn: false, detector: MappedDetector(...), engine: ClaudeEngine(model: "claude-haiku-5-5",
//   apiKey: { "sk-test" }, transport: CostTrackingTransport(inner: stub, price: haiku, maxCost: 1, usageLog: nil), options: .typing),
//   spelling: ScriptedSpelling(flags: []), oracle: NoFacts(), confirmer: Approves())
// two cases → outputs and raw equal the stubbed answers; each sent body's messages[0].content is its case text,
// "thinking" == ["type": "disabled"], no "fallbacks" key, no "anthropic-beta" header
```

`EvalClaudeTests` (new):
```swift
@Test func pricesAreExactModelIDs() {
    #expect(ModelPrice.forModel("claude-haiku-5-5") == ModelPrice(inputPerMTok: 0.10, outputPerMTok: 0.50))
    #expect(ModelPrice.forModel("claude-sonnet-5-5") == ModelPrice(inputPerMTok: 2, outputPerMTok: 10))
    #expect(ModelPrice.forModel("claude-opus-5-5") == ModelPrice(inputPerMTok: 4, outputPerMTok: 20))
    for id in ["claude-haiku-4-5", "claude-haiku-5-5-20260101", "haiku", ""] { #expect(ModelPrice.forModel(id) == nil) }
    #expect(abs(ModelPrice.forModel("claude-haiku-5-5")!.cost(input: 1_000, output: 200) - 0.0002) < 1e-12)
}

@Test func costTrackingRecordsEachRequestAndSums() async throws
// stub: two 200 replies with "usage":{"input_tokens":1000,"output_tokens":200}; maxCost 1; usageLog a temp file
// summary == "claude usage: 2 requests, 2000 input tokens, 400 output tokens, $0.0004 of $1.00; $0.000200 a check, $3.00 a month at 500 checks a day"
// usage log lines == [#"{"input_tokens":1000,"output_tokens":200,"cost":0.000200,"total_cost":0.000200}"#,
//                     #"{"input_tokens":1000,"output_tokens":200,"cost":0.000200,"total_cost":0.000400}"#]

@Test func aRequestWhoseCeilingWouldPassTheLimitIsNeverSent() async throws
// maxCost 0.003; each request's body exactly 1_000 bytes (ceiling 0.0001 + 0.002048 = 0.002148);
// first reply's usage 1000 in / 2000 out (cost 0.0011); the second send throws BudgetExceeded,
// the stub saw exactly 1 request, and summary ends with ", stopped at the cost limit"

@Test func aLostAnswerIsChargedItsCeiling() async throws
// maxCost 0.004; body exactly 1_000 bytes (ceiling 0.002148); the stub's first reply is .failure(URLError(.timedOut)):
// the send throws, abs(spent - 0.002148) < 1e-12; the second send throws BudgetExceeded (0.002148 + 0.002148 > 0.004)
// and the stub saw exactly 1 request

@Test func theKeyComesOnlyFromSkaldEvalClaudeKey() throws {
    #expect(try EvalClaudeKey.read(from: ["SKALD_EVAL_CLAUDE_KEY": "sk-eval"]) == "sk-eval")
    for environment in [[:], ["SKALD_EVAL_CLAUDE_KEY": ""], ["ANTHROPIC_API_KEY": "sk-other"]] {
        #expect(throws: EvalUsageError(message: "set SKALD_EVAL_CLAUDE_KEY to a Claude API key")) { try EvalClaudeKey.read(from: environment) }
    }
}

@Test func replayReadsTheProxyFormatByID() throws
// temp file: {"id":"a","lang":"nl","ms":0,"output":"x"} / {"id":"b","lang":"fr","ms":0,"output":null} / "" → ["a": "x"]
```

- [ ] **Step 2: Run, expect failure**

Run: `swift test --package-path Packages/SkaldPlatform27 --filter 'EvalOptionsTests|EvalBarTests|EvalRunnerPathTests|EvalClaudeTests'`
Expected: compile failure.

- [ ] **Step 3: Implement** the interfaces above; `main.swift` wires claude mode (`CostTrackingTransport(inner: URLSessionTransport(), …)`, `ClaudeEngine(… options: options.claudeRequest)`) and replay (`EvalReplay.load`), writes `X.raw.jsonl` whenever `run.raw` is non-empty, prints the summary in claude mode. Update `Eval/README.md` "Running": the four modes, every flag, the three output files, the cap rule, the key variable, and that replay costs nothing and is how guard-off and later re-grades are made.

- [ ] **Step 4: Run, expect pass**

Run: the focused command, then the Platform suite and the Core suite (for the moved `StubTransport`).
Expected: all pass.

- [ ] **Step 5: Offline checks (no key, no request)**

Run: `env -u SKALD_EVAL_CLAUDE_KEY swift run --package-path Packages/SkaldPlatform27 skald-eval --set Eval/seed.jsonl --mode claude --claude-model claude-haiku-5-5 --max-cost 0.01 --out build/eval/no-key.jsonl`
Expected: exit 2, stderr `set SKALD_EVAL_CLAUDE_KEY to a Claude API key`, no `build/eval/no-key.jsonl.usage.jsonl` written.

Run: `swift run --package-path Packages/SkaldPlatform27 skald-eval --set Eval/heldout.jsonl --mode replay --outputs .superpowers/upgrade-evidence/proxy/out-haiku.jsonl`
Expected (the proxy run's figures, `scored-haiku-guardon.txt`): `en … (tp 17, fp 0, fn 0); clean flagged 0/7`, `fr … (tp 15, fp 0, fn 1); clean flagged 0/7`, `nl … (tp 14, fp 0, fn 0); clean flagged 0/7`; the only listed case `fr-h07: fp 0 fn 1`. With `--guard off`: en 17/0/0, fr 16/0/0, nl 14/0/0. This grades; a differing figure is reported to the controller, never tuned away.

- [ ] **Step 6: Commit** (this commit alone; its SHA goes in the PR as the gate commit)

```bash
git add Packages/SkaldPlatform27/Sources/SkaldPlatform27/Eval/EvalRunner.swift \
  Packages/SkaldPlatform27/Sources/SkaldPlatform27/Eval/ClaudeSpend.swift \
  Packages/SkaldPlatform27/Sources/SkaldPlatform27/Eval/EvalInputs.swift \
  Packages/SkaldPlatform27/Sources/skald-eval/main.swift \
  Packages/SkaldCore/Sources/SkaldCoreTestSupport/StubTransport.swift \
  Packages/SkaldCore/Tests/SkaldCoreTests/ClaudeEngineTests.swift \
  Packages/SkaldCore/Tests/SkaldCoreTests/StudioEngineTests.swift \
  Packages/SkaldPlatform27/Tests/SkaldPlatform27Tests/EvalRunnerTests.swift \
  Packages/SkaldPlatform27/Tests/SkaldPlatform27Tests/EvalClaudeTests.swift \
  Eval/README.md
git commit -m "Add Claude and replay modes to the eval tool"
```
(`git mv` already staged the old `StubTransport.swift` path's removal.)

---

### Task 3: A native word is not borrowed for being English too

**Depends on:** Task 2 (the previous task; this fix lands after the eval commit, so the gate run can't see it)

**Files:**
- Modify: `Packages/SkaldCore/Sources/SkaldCore/Guard/EditGuard.swift:297-300` (`englishStem`)
- Modify: `Packages/SkaldCore/Sources/SkaldCoreTestSupport/OutcomeTable.swift` (four rows; line 100's expected reason)
- Modify: `Packages/SkaldCore/Tests/SkaldCoreTests/Fixtures/guard/word-facts.json` (fr `tous`; nl `warm`, `warme`)
- Test: `Packages/SkaldCore/Tests/SkaldCoreTests/EditGuardTests.swift`; the system run `Packages/SkaldPlatform27/Tests/SkaldPlatform27Tests/GuardOutcomeSystemTests.swift` picks up the rows by itself

**Interfaces:**
- Produces: no new API. Superseded in review by commit `bafd781`: `englishStem(_:_:)` is as in v1, and `borrowedWordVerdict` exempts a native-accepted word without an English stem only in a one-for-one edit whose replacement is its near-homophone (see the Values table). The steps below describe the first attempt, `2fb5c5d`.

Mechanism found by review with synthetic cases; nothing from the held-out set feeds it.

- [ ] **Step 1: Record the new words' facts** from `SystemWordOracle` on this Mac (a throwaway `@Test` in SkaldPlatform27Tests printing `await SystemWordOracle().facts(for: ["tous"], language: .fr)` and `["warm", "warme"]` for `.nl`; delete it afterwards), in the fixture's shape (`misspelled`, `english`, `stem`, `lemma`, `function`, `only`).

- [ ] **Step 2: Write the failing tests.** Rows appended to `outcomeTable`:

```swift
Row("A French word English also has, fixed to another French word", .fr,
    "Tout les serveurs sont à jour", "Tous les serveurs sont à jour", .keep),
Row("A French borrowing fixed to a French word", .fr,
    "J'ai mergé le correctif", "J'ai fusionné le correctif", .drop(.borrowedWord)),
Row("A Dutch borrowing fixed to a Dutch word", .nl,
    "Ik heb de fix gemerged", "Ik heb de fix gemerkt", .drop(.borrowedWord)),
Row("A Dutch word English also has, fixed to another Dutch word", .nl,
    "Het was een warm dag", "Het was een warme dag", .keep),
```
Line 100, "A French adverb is not a function word" ("plus" → "jamais"): expected `.drop(.replacement)`. "plus" is in the French dictionary, so it is no longer a borrowed word; it stays a drop, as its Dutch and English siblings do, and the spec lets a drop's recorded reason change.

In `EditGuardTests`:
```swift
@Test func aWordTheParagraphsDictionaryAcceptsIsNotBorrowedForBeingEnglishToo() {
    let paragraph = "Tout les serveurs sont à jour"
    let found = TextDiff.edits(from: paragraph, to: "Tous les serveurs sont à jour")
    let guardrail = EditGuard(neverTouch: [])
    #expect(guardrail.verdict(for: found[0], in: paragraph, language: .fr, source: .model, facts: WordFacts(english: ["tout"])) == .keep)
    #expect(guardrail.verdict(for: found[0], in: paragraph, language: .fr, source: .model,
                              facts: WordFacts(misspelled: ["tout"], english: ["tout"])) == .drop(.borrowedWord))
}
```

- [ ] **Step 3: Run, expect failure**

Run: `swift test --package-path Packages/SkaldCore --filter 'outcome|aWordTheParagraphsDictionary'`
Expected: the "Tout" and "warm" rows and the new test fail with `.drop(.borrowedWord)`; the adverb row fails with `.drop(.borrowedWord)` ≠ `.drop(.replacement)`.

- [ ] **Step 4: Implement** the `englishStem` change.

- [ ] **Step 5: Run, expect pass.** Core suite; then `swift test --package-path Packages/SkaldPlatform27 --filter 'GuardOutcome'` (system word facts).
Expected: all pass. Any other existing row changing keep/drop/undecided, or any reason changing besides line 100's: stop and report to the controller; never adjust the rule to a row.

- [ ] **Step 6: Commit**

```bash
git add Packages/SkaldCore/Sources/SkaldCore/Guard/EditGuard.swift \
  Packages/SkaldCore/Sources/SkaldCoreTestSupport/OutcomeTable.swift \
  Packages/SkaldCore/Tests/SkaldCoreTests/Fixtures/guard/word-facts.json \
  Packages/SkaldCore/Tests/SkaldCoreTests/EditGuardTests.swift
git commit -m "Stop counting a native word as borrowed because English has it too"
```

---

### Task 4: Settings version 2 and the three-way per-app setting

**Safety boundary: settings migration. Per-task review.**

**Depends on:** Task 3 (the previous task; order only)

**Files:**
- Modify: `Packages/SkaldCore/Sources/SkaldCore/Settings/Settings.swift`
- Modify: `Skald/SettingsModel.swift:69-82`, `Skald/Settings/AppsPane.swift`, `Skald/StatusItemController.swift` (`FrontApp`, `Actions.setApp`, the toggle), `Skald/CompositionRoot.swift:85-94, 326-329`
- Test: `Packages/SkaldCore/Tests/SkaldCoreTests/SettingsStoreTests.swift`, `SkaldTests/SettingsModelTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum AppMode: String, Codable, CaseIterable, Sendable { case on, thisMacOnly, off }
  Settings (changed and new members):
      public static let currentVersion = 2                                // was 1
      public var appOverrides: [String: AppMode]                          // was [String: Bool]
      public var claudeTyping: Bool                                       // false
      public var claudeLanguages: [Language: Bool]                        // [.nl: true, .fr: true]
      public var claudeTypingModel: String                                // "claude-haiku-5-5"
      public static func defaultMode(app bundleID: String) -> AppMode     // .off for defaultOffApps, else .on
      public func mode(app bundleID: String) -> AppMode                   // override, else the default
      public func isEnabled(app bundleID: String) -> Bool                 // mode(app:) != .off
  SettingsModel.setApp(_ bundleID: String, mode: AppMode)                 // replaces setApp(_:enabled:); stores only a non-default mode
  StatusItemController.FrontApp(bundleID: String, name: String, mode: AppMode)
  StatusItemController.Actions.setApp: (_ bundleID: String, _ mode: AppMode) -> Void
  ```
- Decoding: `version` is read for the store's probe but the decoded value is always `currentVersion`; `appOverrides` values decode from `"on"`, `"thisMacOnly"`, `"off"`, `true` (→ on) or `false` (→ off), and an entry with any other value is dropped alone; `claudeLanguages` uses the lenient `languageChecks` helper; the other new keys default when absent.

- [ ] **Step 1: Write the failing tests** (`SettingsStoreTests`):

```swift
private let v1File = """
{"version": 1, "launchAtLogin": false, "panelHotkey": {"keyCode": 3, "modifiers": 4096},
 "pausedUntil": "2027-01-15T08:00:00.000Z", "appOverrides": {"com.mitchellh.ghostty": true, "com.apple.Notes": false},
 "neverTouch": ["Brightline", "Talos"], "modelChecks": {"en": true, "nl": true, "fr": false},
 "typingChecks": {"en": true, "nl": true, "fr": true}, "panelDefaultEngine": "claude",
 "studio": {"api": "openAICompatible", "baseURL": "http://studio.local:1234", "model": "m"},
 "claudeModel": "claude-sonnet-5-5"}
"""

@Test func aV1FileIsReadWithoutLoss() throws
// load → .loaded(s): s.version == 2; s.launchAtLogin == false; s.panelHotkey == Hotkey(keyCode: 3, modifiers: 4096);
// s.pausedUntil == the 2027-01-15T08:00:00Z date; s.appOverrides == ["com.mitchellh.ghostty": .on, "com.apple.Notes": .off];
// s.neverTouch == ["Brightline", "Talos"]; s.modelChecks == [.en: true, .nl: true, .fr: false]; s.typingChecks all true;
// s.panelDefaultEngine == .claude; s.studio == StudioEndpoint(api: .openAICompatible, baseURL: "http://studio.local:1234", model: "m");
// s.claudeModel == "claude-sonnet-5-5"; s.claudeTyping == false; s.claudeLanguages == [.nl: true, .fr: true];
// s.claudeTypingModel == "claude-haiku-5-5"

@Test func aV1FileSavedAgainIsWrittenAsVersion2() throws
// load the v1 file, save it, read the JSON: "version" == 2 and "appOverrides" == ["com.apple.Notes": "off", "com.mitchellh.ghostty": "on"];
// load again == the first load

@Test func anUnknownAppModeDropsOnlyThatEntry() throws
// {"version": 2, "appOverrides": {"a": "sometimes", "b": "thisMacOnly"}, "neverTouch": ["Talos"]} → .loaded with
// appOverrides == ["b": .thisMacOnly] and neverTouch == ["Talos"] (not .recoveredFromCorrupt)

```
`defaultOffAppsAreOffUnlessOverridden`, with modes: `mode(app: "com.mitchellh.ghostty") == .off` and `mode(app: "com.apple.Notes") == .on` by default; ghostty overridden `.on` is enabled; Notes overridden `.off` is not; Notes overridden `.thisMacOnly` has `mode == .thisMacOnly` and is enabled.
Extend `settingsRoundTrip` with `appOverrides["com.apple.Notes"] = .thisMacOnly`, `claudeTyping = true`, `claudeLanguages = [.nl: true, .fr: false]`, `claudeTypingModel = "claude-sonnet-5-5"` (replacing its `= true` override with `.on`). `missingFileLoadsFreshDefaults`: `version == 2`, `claudeTyping == false`, `claudeLanguages == [.nl: true, .fr: true]`, `claudeTypingModel == "claude-haiku-5-5"`. The future file in `futureVersionIsReadOnlyAndNeverOverwritten` and in `aSuccessfulLoadClearsTheReadOnlyFlag` becomes version 3 (version 2 is now current).

`SettingsModelTests.anAppOverrideIsStoredOnlyWhereItDiffersFromTheShippedDefault`, rewritten: Notes `.thisMacOnly` → `["com.apple.Notes": .thisMacOnly]`; Notes `.on` → empty; Terminal `.on` → `["com.apple.Terminal": .on]`; Terminal `.thisMacOnly` → `[… : .thisMacOnly]`; Terminal `.off` → empty.

- [ ] **Step 2: Run, expect failure**

Run: `swift test --package-path Packages/SkaldCore --filter 'aV1File|anUnknownAppMode|defaultOffApps|settingsRoundTrip|missingFile|futureVersion|aSuccessfulLoad'`
Expected: compile failure.

- [ ] **Step 3: Implement** the Core interfaces, then the app: `setApp(_:mode:)`; the Apps pane's per-app switch becomes a menu `Picker` with "On", "This Mac only", "Off", and its caption reads "Skald checks what you type in the apps turned on here. Nothing you type in an app kept on This Mac only goes to Claude, and the panel offers This Mac only there. Terminals, code editors and password managers start off."; the status menu's item reads "Turn Off for ‹App›" unless the mode is `.off` (sets `.off`), else "Turn On for ‹App›" (sets `.on`).

- [ ] **Step 4: Run, expect pass.** Core suite, App suite.

- [ ] **Step 5: Commit**

```bash
git add Packages/SkaldCore/Sources/SkaldCore/Settings/Settings.swift \
  Packages/SkaldCore/Tests/SkaldCoreTests/SettingsStoreTests.swift \
  Skald/SettingsModel.swift Skald/Settings/AppsPane.swift Skald/StatusItemController.swift Skald/CompositionRoot.swift \
  SkaldTests/SettingsModelTests.swift
git commit -m "Store a three-way setting per app and the Claude typing settings"
```

---

### Task 5: Routing to Claude, and the panel in a kept app

**Safety boundary: what is sent off the Mac. Per-task review.**

**Depends on:** Task 4 (the previous task; `Settings.mode(app:)`, `claudeTyping`, `claudeLanguages`)

**Files:**
- Modify: `Packages/SkaldCore/Sources/SkaldCore/Engines/EngineRouter.swift`, `Packages/SkaldCore/Sources/SkaldCore/Engines/LiveRouter.swift:12-14`, `Packages/SkaldCore/Sources/SkaldCore/Engines/Engine.swift` (`.keptOnThisMac`), `Packages/SkaldCore/Sources/SkaldCore/Engines/PanelSession.swift` (init `app:`, lines 93-95 and 105)
- Modify: `Packages/SkaldCore/Sources/SkaldCore/Pipeline/CheckPipeline.swift:444` (`typing(language)` → `onDevice(language)`: no behaviour change)
- Modify: `Skald/CompositionRoot.swift:234-282` (pass `source?.bundleIdentifier`; `pickerEngines(app:)`, `panelDefault(app:)`), `Skald/StatusItemController.swift` (`.keptOnThisMac` explanation "this app is kept on this Mac")
- Test: `Packages/SkaldCore/Tests/SkaldCoreTests/EngineRouterTests.swift`, `Packages/SkaldCore/Tests/SkaldCoreTests/PanelSessionTests.swift`, `SkaldTests/StatusTitleTests.swift` (reason list)

**Interfaces:**
- Consumes: `Settings.mode(app:)`, `claudeTyping`, `claudeLanguages` (Task 4).
- Produces:
  ```swift
  public enum TypingRoute: Equatable, Sendable { case model, claude, spellingOnly(UnavailableReason), off }
  extension EngineRouter {
      /// .claude when the language is Dutch or French, the switch is on, the language is ticked, a key is stored and
      /// the app's mode is .on; otherwise onDevice(language). Never .claude for English.
      public func typing(_ language: Language, app: String) -> TypingRoute
      public func onDevice(_ language: Language) -> TypingRoute      // v1's typing(_:), verbatim; never .claude
      public var canConfirmOnDevice: Bool                              // appleAvailability == nil && !thermalPaused
      public var claudeTypingLanguages: [Language]                     // [.nl, .fr] order: switch on, ticked, key stored
      public func panel(requested: EngineKind?, app: String?) -> PanelRoute
      public func alternatives(to engine: EngineKind, app: String?) -> [EngineKind]
      public func pickerEngines(app: String?) -> [EngineKind]           // replaces the pickerEngines property
      public func panelDefault(app: String?) -> EngineKind
  }
  LiveRouter.modelAllowed(_:) == current.onDevice(language) == .model     // the panel's Fix gate, unchanged in effect
  PanelSession.init(capture:text:detector:editGuard:oracle:confirmer:engines:router:access:app: String?, fieldLanguage:)
  UnavailableReason.keptOnThisMac
  ```
- In an app whose mode is `.thisMacOnly`: `pickerEngines` is `[.thisMac]`; `panelDefault` is `.thisMac`; `panel(requested: nil)` uses This Mac, or is `.unavailable(.thisMac, reason, alternatives: [])` when Apple is unavailable; a request for `.claude` or `.macStudio` is `.unavailable(engine, .keptOnThisMac, alternatives: [.thisMac])` (empty when Apple is unavailable); `alternatives` never lists `.claude` or `.macStudio`. With `app: nil` or any other mode, v1's answers.

- [ ] **Step 1: Write the failing tests.** Existing router tests call `onDevice(_:)` where they called `typing(_:)` and `pickerEngines(app: nil)`. New, with `mail = "com.example.mail"`, `chat = "com.example.chat"` and a helper whose settings are the shipped ones plus `claudeTyping = true` and a stored key:

```swift
@Test func theSwitchOffKeepsEveryLanguageOnThisMac()        // claudeTyping false: typing(.nl, app: mail) == .spellingOnly(.languageOff), (.fr) == .off, (.en) == .model
@Test func aTickedLanguageGoesToClaude()                    // typing(.nl, app: mail) == .claude, typing(.fr, app: mail) == .claude
@Test func anUntickedLanguageStaysOnThisMac()               // claudeLanguages[.fr] = false: (.fr) == .off, (.nl) == .claude
@Test func englishNeverGoesToClaude()                       // claudeLanguages[.en] = true: typing(.en, app: mail) == .model; claudeTypingLanguages == [.nl, .fr]
@Test func anAppKeptOnThisMacKeepsItsTyping()               // appOverrides[mail] = .thisMacOnly: (.nl) == .spellingOnly(.languageOff), (.fr) == .off
@Test func withoutAKeyNothingGoesToClaude()                 // key false: (.nl) == .spellingOnly(.languageOff); claudeTypingLanguages == []
@Test func theOnDeviceSwitchesAreNotReadForARoutedLanguage()
// typingChecks[.fr] = false, modelChecks[.fr] = false, apple: .appleIntelligenceOff, thermalPaused: true:
// typing(.fr, app: mail) == .claude, onDevice(.fr) == .off, and the settings value is unchanged
@Test func confirmingOnDeviceNeedsAppleAndNoThermalPause()  // true; false with apple .modelNotReady; false when thermal-paused
@Test func anAppKeptOnThisMacOffersOnlyThisMacInThePanel()
// panelDefaultEngine .claude, studio configured, appOverrides[chat] = .thisMacOnly:
// pickerEngines(app: chat) == [.thisMac]; panelDefault(app: chat) == .thisMac; panel(requested: nil, app: chat) == .use(.thisMac);
// panel(requested: .claude, app: chat) == .unavailable(.claude, .keptOnThisMac, alternatives: [.thisMac]);
// alternatives(to: .thisMac, app: chat) == []; pickerEngines(app: mail) == [.thisMac, .macStudio, .claude];
// panelDefault(app: mail) == .claude; pickerEngines(app: nil) == pickerEngines(app: mail)
@Test func aKeptAppWithoutAppleHasNoPanelEngine()            // apple .appleIntelligenceOff: panel(requested: nil, app: chat) == .unavailable(.thisMac, .appleIntelligenceOff, alternatives: [])
```
`PanelSessionTests` (the file's `Rig` takes `app:`):
```swift
@Test func aSessionInAnAppKeptOnThisMacNeverRunsClaude() async
// settings panelDefaultEngine .claude, appOverrides["com.example.chat"] = .thisMacOnly, key stored, app "com.example.chat":
// run(.fix, on: nil) is .revised(…, engine: .thisMac); run(.fix, on: .claude) == .unavailable(.claude, .keptOnThisMac, alternatives: [.thisMac]);
// the Claude fake's requests are empty
```

- [ ] **Step 2: Run, expect failure.** Core suite → compile failure (`typing(_:app:)`, `onDevice(_:)` unknown).

- [ ] **Step 3: Implement.** The router owns every rule above; `CompositionRoot.panelHotkeyPressed` passes the frontmost app's bundle identifier to `PanelSession`, `pickerEngines(app:)` and `panelDefault(app:)` (this replaces `settings.panelDefaultEngine` there).

- [ ] **Step 4: Run, expect pass.** Core suite, App suite.

- [ ] **Step 5: Commit**

```bash
git add Packages/SkaldCore/Sources/SkaldCore/Engines/EngineRouter.swift \
  Packages/SkaldCore/Sources/SkaldCore/Engines/LiveRouter.swift \
  Packages/SkaldCore/Sources/SkaldCore/Engines/Engine.swift \
  Packages/SkaldCore/Sources/SkaldCore/Engines/PanelSession.swift \
  Packages/SkaldCore/Sources/SkaldCore/Pipeline/CheckPipeline.swift \
  Packages/SkaldCore/Tests/SkaldCoreTests/EngineRouterTests.swift \
  Packages/SkaldCore/Tests/SkaldCoreTests/PanelSessionTests.swift \
  Skald/CompositionRoot.swift Skald/StatusItemController.swift SkaldTests/StatusTitleTests.swift
git commit -m "Route Dutch and French to Claude by language and app, and keep a kept app's panel on this Mac"
```

---

### Task 6: Backing off when Claude fails

**Depends on:** Task 5 (the previous task; order only); Task 1 (`UnavailableReason.claudeKeyRejected`, `.claudeRateLimited`)

**Files:**
- Create: `Packages/SkaldCore/Sources/SkaldCore/Engines/ClaudeBackoff.swift`
- Test: Create `Packages/SkaldCore/Tests/SkaldCoreTests/ClaudeBackoffTests.swift`

**Interfaces:**
- Consumes: `UnavailableReason.claudeKeyRejected`, `.claudeRateLimited` (Task 1).
- Produces:
  ```swift
  public enum ClaudeTrouble: String, Equatable, Sendable {
      case unreachable, keyRejected, rateLimited, declined
      public init?(_ failure: EngineFailure)   // nil for .cancelled
  }
  /// Pure, on the caller's clock (durations since the pipeline's origin).
  public struct ClaudeBackoff: Sendable {
      public static let suspendAfter = 2
      public static let firstSuspension: Duration = .seconds(30)
      public static let longestSuspension: Duration = .seconds(300)
      public static let rememberedTexts = 32
      public private(set) var trouble: ClaudeTrouble?
      public init()
      public func isSuspended(at now: Duration) -> Bool
      public func mayAsk(about text: String, at now: Duration) -> Bool   // not suspended and text not among the remembered failures
      public mutating func failed(_ trouble: ClaudeTrouble, text: String, at now: Duration)
      public mutating func succeeded()                                    // clears streak, suspension, trouble; keeps remembered texts
  }
  ```
- Classification: `.timedOut`, `.failed`, `.unavailable` with any other reason → `.unreachable`; `.unavailable(.claudeKeyRejected)` and `.unavailable(.claudeKeyMissing)` → `.keyRejected`; `.unavailable(.claudeRateLimited)` → `.rateLimited`; `.refused`, `.truncated` → `.declined`.
- `failed`: remembers the text (by `hashValue`, the last 32) and sets `trouble`. `.declined` leaves the streak alone. Any other adds one to the streak; from the second, the suspension ends at `now + min(30 s × 2^(streak − 2), 300 s)`.

- [ ] **Step 1: Write the failing tests** (`struct ClaudeBackoffTests`):

```swift
@Test func failuresAreSortedByWhatTheyMean()
// ClaudeTrouble(.timedOut) == .unreachable; (.failed) == .unreachable; (.unavailable(.claudeKeyRejected)) == .keyRejected;
// (.unavailable(.claudeKeyMissing)) == .keyRejected; (.unavailable(.claudeRateLimited)) == .rateLimited;
// (.refused) == .declined; (.truncated) == .declined; (.cancelled) == nil

@Test func oneFailureFallsBackWithoutSuspending()
// failed(.unreachable, text: "a", at: .zero): isSuspended(at: .zero) == false; trouble == .unreachable;
// mayAsk(about: "a", at: .seconds(1)) == false; mayAsk(about: "b", at: .seconds(1)) == true

@Test func repeatedFailuresSuspendForAnIntervalThatDoublesToFiveMinutes()
// failures (texts t1…t7) at 0 s, 1 s, 31 s, 91 s, 211 s, 451 s, 751 s; after the one at 1 s:
// isSuspended(at: .milliseconds(30_999)) true, (at: .seconds(31)) false; then the suspension ends at
// 91 s, 211 s, 451 s, 751 s and 1_051 s (each checked at the end minus 1 ms → true, at the end → false)

@Test func aSuccessClearsTheSuspensionAndTheTroubleButNotTheFailedTexts()
// two failures → succeeded(): isSuspended false, trouble nil, mayAsk("t1") false, mayAsk("c") true;
// one more failure does not suspend

@Test func aDeclinedParagraphIsNotAskedAgainButSuspendsNothing()
// five .declined failures on five texts: never suspended, trouble == .declined, each text's mayAsk false

@Test func theFailedTextsAreTheLast32()
// 33 .declined failures, texts "t0"…"t32": mayAsk("t0") true, mayAsk("t1") false
```

- [ ] **Step 2: Run, expect failure.** `swift test --package-path Packages/SkaldCore --filter ClaudeBackoffTests` → compile failure.
- [ ] **Step 3: Implement** `ClaudeBackoff.swift`.
- [ ] **Step 4: Run, expect pass.** Focused, then the Core suite.
- [ ] **Step 5: Commit**

```bash
git add Packages/SkaldCore/Sources/SkaldCore/Engines/ClaudeBackoff.swift \
  Packages/SkaldCore/Tests/SkaldCoreTests/ClaudeBackoffTests.swift
git commit -m "Suspend Claude checks after repeated failures, for a growing interval"
```

---

### Task 7: The pipeline checks the caret's paragraph with Claude

**Safety boundary: what is sent off the Mac. Per-task review.**

**Depends on:** Task 6 (the previous task; order only); Task 5 (`typing(_:app:)`, `onDevice(_:)`, `canConfirmOnDevice`); Task 4 (the Claude settings, `AppMode`)

**Files:**
- Modify: `Packages/SkaldCore/Sources/SkaldCore/Pipeline/CheckPipeline.swift` (init, `checkModel`, `spell`, `mayConfirm`, `route`, `setRouteHook`, `update(settings:)`, `anchored`)
- Modify: `Packages/SkaldCore/Sources/SkaldCore/Issues/Issue.swift`, `Packages/SkaldCore/Sources/SkaldCore/Issues/IssueTracker.swift:49-58` (revalidate carries `engine`)
- Create: `Packages/SkaldCore/Tests/SkaldCoreTests/Support/PipelineRig.swift`: the `Rig` of `CheckPipelineTests.swift`, renamed `PipelineRig`, internal, extended with `claude: FakeEngine?`, a key flag, a record of the models the factory was asked for, and word facts for every language. Everything it shares (its fields `fieldA`/`fieldB`, the pause, `makeSettings`, `engineRouter`, `GatedOracle`) becomes a static member or nested type of `PipelineRig` (`PipelineRig.fieldA`, `PipelineRig.makeSettings(…)`), never an internal top-level name: other test files declare private top-level names like these, and an internal one beside them is ambiguous.
- Modify: `Packages/SkaldCore/Tests/SkaldCoreTests/CheckPipelineTests.swift` (uses `PipelineRig`; its route-hook closures take the new lookup kind; no test changes)
- Create: `Packages/SkaldCore/Tests/SkaldCoreTests/ClaudeTypingTests.swift`
- Test: `Packages/SkaldCore/Tests/SkaldCoreTests/IssueTrackerTests.swift`

**Interfaces:**
- Consumes: `typing(_:app:)`, `onDevice(_:)`, `canConfirmOnDevice` (Task 5); `Settings.claudeTypingModel`, `claudeLanguages`, `appOverrides` (Task 4).
- Produces:
  ```swift
  CheckPipeline.init(access:, apple:, claude: (@Sendable (_ model: String) -> any Engine)? = nil, spelling:, detector:,
                     oracle:, confirmer:, clock:, settings:, router:)
  public static let claudeTimeout: Duration = .seconds(5)   // on CheckPipeline
  Issue.init(id:key:parent:chunk:edit:source:language:engine: EngineKind? = nil)
  public let engine: EngineKind?   // on Issue: .claude or .thisMac for a model issue, nil for spelling
  enum RouteLookup: Sendable { case spelling, model }                    // internal, for the test hook
  CheckPipeline.setRouteHook(_ hook: (@Sendable (Language, RouteLookup) async -> Void)?)   // was (Language)
  ```
- Model check: the route is `typing(language, app: key.field.app)`. `.claude` sends `EngineRequest(action: .check, language:, text: chunk.text)` to `claude(settings.claudeTypingModel)`, raced against `claudeTimeout` on the injected clock (at the deadline the request's task is cancelled and its answer, if it comes, ignored); `.model` runs Apple as v1; anything else is dropped as v1. A Claude failure or timeout is dropped here; Task 8 turns it into a fallback.
- Before the send: every route lookup goes through `route(…)`, which calls the hook with its kind; after the model check's lookup, the epoch, generation and a `.claude` route are checked again, and nothing awaits between that check and the engine call. A pause, a focus change or a settings update (the app kept on this Mac, the switch off) that lands after the check started therefore sends nothing.
- After the answer: `ModelAnswer.judge` as for Apple; the epoch, generation and a route still `.claude` for that language and app must hold, or nothing is published. Confirmation on the Claude path is allowed when `router.current.canConfirmOnDevice` and Apple has not been found unavailable.
- Model issues carry `engine: .claude` or `.thisMac`; `IssueTracker.revalidate` keeps it.
- Spelling, at the caret and in the background, follows `router.current.onDevice(language)`. When that is `.off` while the model route for the paragraph's language and the field's app is `.claude`, the spelling job neither clears nor forgets the key: it ends. (v1's off branch, `CheckPipeline.swift:364-369`, clears the key's issues, Claude's included, and at the caret sends `.forget`, which also drops the key from the scheduler's `modelChecked`, so the next caret move would send the paragraph again; in the background it clears the key when a refocus re-queues it.) When the model route is not `.claude`, v1's branch stands.
- `update(settings:)` rechecks when `claudeTyping`, `claudeLanguages` or `appOverrides` change, as for `typingChecks`/`modelChecks`.

- [ ] **Step 1: Extract the rig.** Move `Rig` and its constants to `Support/PipelineRig.swift` as above; run `swift test --package-path Packages/SkaldCore --filter CheckPipelineTests`; expected: every test passes unchanged.

- [ ] **Step 2: Write the failing tests** (`ClaudeTypingTests`, `@Suite(.timeLimit(.minutes(1)))`). Rig: `Settings()` with `claudeTyping = true` (shipped on-device switches: Dutch spelling only, French off), key stored, `FakeLanguageDetector` (markers "Ik heb" → nl, "J'ai" → fr), `FakeSpelling(["gisterren": "gisteren"])`, Claude `FakeEngine.correcting(["gisterren": "gisteren", "word": "wordt", "serveur": "serveurs"])` unless a test says otherwise, field app `com.example.mail`. Texts: `dutch = "Ik heb de fix gisterren nagekeken en het word morgen uitgerold"`, `dutch2 = "Ik heb gisterren ook de logs bekeken"`, `french = "J'ai vérifié les serveur ce matin et tout marche"`, `french2 = "J'ai aussi regardé les journaux hier soir"`, and `flew` for English.

```swift
@Test func aDutchParagraphGoesToClaudeAndOnlyItsTextIsSent()
// field dutch + "\n" + dutch2, caret in dutch: claude requests == one request with action .check, language .nl, text dutch,
// confirmOriginal nil, confirmReplacement nil; the factory was asked for ["claude-haiku-5-5"]; Apple's requests empty;
// model issues' words == ["gisterren", "word"], each engine == .claude
@Test func dutchSpellingShowsAtOnceAndClaudeWithdrawsWhatItLeftAlone()
// Claude gated, correcting only "word": before release, visible == spelling "gisterren" in dutch and in dutch2;
// after release, dutch's "gisterren" flag is gone, "word" is a Claude issue, dutch2's flag stays; dutch2 never sent
@Test func aFrenchParagraphShowsNothingUntilClaudeAnswers()
// field french + "\n" + french2, Claude gated: before release visible is empty and FakeSpelling has no French call;
// after release visible == ["serveur"] with engine .claude; Claude's texts == [french]
@Test func claudesFrenchIssuesSurviveTheCaretLeavingAndComingBack()
// after the previous: caret to french2 (checked: Claude's texts == [french, french2]), back to french, then one more
// caret move inside french: still 2 requests, and "serveur" (engine .claude) is still visible
@Test func claudesFrenchIssuesSurviveARefocus()
// after the previous: focus fieldB, then fieldA again with the caret in french2 and let the background pass run:
// "serveur" (engine .claude) is still visible and Claude's requests are still 2
@Test func englishStaysOnTheMac()              // flew: Apple got [flew], Claude got nothing, model issues have engine .thisMac
@Test func anAppKeptOnThisMacSendsNothing()     // appOverrides["com.example.mail"] = .thisMacOnly: Claude got nothing; "gisterren" flagged
@Test func nothingIsSentWhilePaused()           // setPaused(true), focus, edit, pause passes: Claude got nothing, visible empty
@Test func withoutAKeyDutchIsSpellingOnly()      // router built without a key: Claude got nothing; "gisterren" flagged
@Test func aNewerPauseCancelsTheRunningRequest()
// Claude gated; request 0 in flight; the paragraph is edited to a new text and the pause passes: request 1 has the new text;
// release both: Claude's cancelled == [0], and only the new text's issues are published
@Test func anAnswerWithinTheTimeoutIsUsed()     // gated; clock advanced 4_999 ms; release: "word" is published
@Test func anAnswerAfterTheTimeoutIsIgnored()   // gated; clock advanced 5 s; release: no Claude issue, cancelled == [0]
@Test func confirmationStaysOnThisMacForAClaudeAnswer()
// Claude corrects "paris" → "Paris" in "Ik heb de fix voor paris klaar gezet vandaag": the confirmer was asked ["paris"]
// although modelChecks[.nl] is false; with the router's apple .appleIntelligenceOff it is asked nothing and the edit is dropped
@Test func anAnswerArrivingAfterTheSwitchWentOffIsDropped()
// gated; request in flight; update(settings with claudeTyping false); release: no Claude issue published
@Test func aPauseBeforeTheSendSendsNothing()
// as v1's pausingDuringASpellingLookupPublishesNothing: a hook (this file's own, private) holds the first route lookup
// of kind .model for .nl; setPaused(true); release; drain: Claude's requests are empty, no Claude issue
@Test func keepingTheAppOnThisMacBeforeTheSendSendsNothing()
// the same hold; rig.update(settings with appOverrides["com.example.mail"] = .thisMacOnly); release; drain; then
// pass the pause again: Claude's requests are empty, "gisterren" flagged
@Test func turningClaudeOnRechecksTheField()    // switch off: Claude got nothing; update with it on and pass the pause: Claude got [dutch]
```
`IssueTrackerTests`:
```swift
@Test func revalidationKeepsTheEngineThatFoundAnIssue()
// an issue with engine .claude; revalidate with a snapshot where its paragraph moved: the kept issue's engine == .claude
```

- [ ] **Step 3: Run, expect failure.** `swift test --package-path Packages/SkaldCore --filter 'ClaudeTypingTests|revalidationKeepsTheEngine'` → compile failure.
- [ ] **Step 4: Implement** the behaviour above.
- [ ] **Step 5: Run, expect pass.** Focused, then the Core suite (the 58 `CheckPipelineTests` included).
- [ ] **Step 6: Commit**

```bash
git add Packages/SkaldCore/Sources/SkaldCore/Pipeline/CheckPipeline.swift \
  Packages/SkaldCore/Sources/SkaldCore/Issues/Issue.swift \
  Packages/SkaldCore/Sources/SkaldCore/Issues/IssueTracker.swift \
  Packages/SkaldCore/Tests/SkaldCoreTests/Support/PipelineRig.swift \
  Packages/SkaldCore/Tests/SkaldCoreTests/CheckPipelineTests.swift \
  Packages/SkaldCore/Tests/SkaldCoreTests/ClaudeTypingTests.swift \
  Packages/SkaldCore/Tests/SkaldCoreTests/IssueTrackerTests.swift
git commit -m "Check the caret's Dutch and French paragraph with Claude while typing"
```

---

### Task 8: Fallback, backoff and the Claude status

**Safety boundary: what is sent off the Mac (the status before the send). Per-task review.**

**Depends on:** Task 7 (the previous task; the Claude path); Task 6 (`ClaudeBackoff`, `ClaudeTrouble`)

**Files:**
- Modify: `Packages/SkaldCore/Sources/SkaldCore/Pipeline/CheckPipeline.swift`
- Create: `Packages/SkaldCore/Sources/SkaldCore/Pipeline/ClaudeStatus.swift`
- Test: Create `Packages/SkaldCore/Tests/SkaldCoreTests/ClaudeFailureTests.swift`; Task 7's `ClaudeTypingTests` run again unchanged

**Interfaces:**
- Consumes: `ClaudeBackoff`, `ClaudeTrouble` (Task 6); the Claude path (Task 7).
- Produces:
  ```swift
  public struct ClaudeStatus: Equatable, Sendable {
      public var sending: Bool                 // the focused field's checks go to Claude now
      public var trouble: ClaudeTrouble?       // from a failed request until the next success
      public init(sending: Bool, trouble: ClaudeTrouble?)
      public static let quiet = ClaudeStatus(sending: false, trouble: nil)
  }
  extension CheckPipeline {
      public nonisolated var claudeStatus: AsyncStream<ClaudeStatus> { get }   // newest only, like `issues`
      public func resetClaude()                                                 // a new key: a fresh ClaudeBackoff
      var lastClaudeStatus: ClaudeStatus { get }                                // internal, the value last yielded; for tests
  }
  ```
- `sending` = not paused, a factory exists, the focused field's last confident language routes to `.claude` for the field's app, and the backoff isn't suspended. Recomputed and yielded (when changed) on focus, pause and resume, settings updates, every route lookup, every Claude outcome and `resetClaude()`; on the sync paths through a tracked job, so `drain()` covers it.
- **The status says `sending: true` before the engine is called**, every time, and publishing it adds no suspension point: the pre-send status is computed synchronously from the `EngineRouter` value the check's final route lookup just read and the pipeline's own state, so Task 7's rule (nothing awaits between the last check and the engine call) still holds and its race tests still pass.
- A request is sent only when `backoff.mayAsk(about: chunk.text, at: now)`; otherwise the chunk takes `onDevice(language)`.
- A failure (the timeout included, cancellation excluded) calls `backoff.failed(ClaudeTrouble(failure)!, text:, at:)`, yields the status, and falls back in the same job: `onDevice == .model` runs Apple as v1 (issues with `engine: .thisMac`); otherwise the check is dropped. Issues already shown are never cleared by a failure. A success calls `backoff.succeeded()`.

- [ ] **Step 1: Write the failing tests** (rig and texts as in Task 7):

```swift
@Test func theStatusSaysSendingBeforeTheRequestLeaves()
// a test engine that records `await pipeline.lastClaudeStatus` inside run(_:) and answers like the fake:
// recorded == [ClaudeStatus(sending: true, trouble: nil)]; in an English field, a kept app and while paused, lastClaudeStatus.sending == false
@Test func aFailedRequestFallsBackAndIsNotRetriedForTheSameText()
// Claude fails .failed: trouble == .unreachable, "gisterren" still flagged, sending still true;
// recheck at the caret: Claude's requests still 1; edit to a new text and pass the pause: request 2 is sent
@Test func repeatedFailuresSuspendClaudeOnTheInjectedClock()
// Claude always fails: after the second failure (time T, read from the rig's clock), sending == false and a new text at T + 29 s
// is not sent; at T + 30 s a new text is sent; it fails, and a new text at T + 30 s + 59 s is not sent, at + 60 s it is
@Test func aSuccessClearsTheTroubleAndTheSuspension()   // after the suspension ends, a success: status == ClaudeStatus(sending: true, trouble: nil)
@Test func aTimeoutIsAFailure()                           // gated, clock advanced 5 s: trouble == .unreachable; "gisterren" still flagged
@Test func aRejectedKeyAndARateLimitSaySo()               // .unavailable(.claudeKeyRejected) → .keyRejected; .unavailable(.claudeRateLimited) → .rateLimited
@Test func aRefusalSuspendsNothing()                      // three refusals on three texts: trouble == .declined, sending true, a fourth text is sent
@Test func theFallbackIsWhatTheOnDeviceSwitchesSay()
// modelChecks[.nl] = true and Claude fails: Apple got [dutch] and its issues have engine .thisMac;
// with the shipped switches Apple gets nothing; a French failure shows nothing (French typing off)
@Test func issuesShownStayWhenALaterRequestFails()       // dutch answered ("word" shown); caret to dutch2, which fails: "word" still visible
@Test func aNewKeyLetsClaudeBeAskedAgain()                // suspended, then resetClaude(): trouble nil; recheck of the failed text sends it
@Test func cancellationIsNotAFailure()                    // a newer pause cancels the request: trouble nil, no suspension
```

- [ ] **Step 2: Run, expect failure.** `swift test --package-path Packages/SkaldCore --filter ClaudeFailureTests` → compile failure.
- [ ] **Step 3: Implement** the behaviour above.
- [ ] **Step 4: Run, expect pass.** Focused, then the Core suite (`ClaudeTypingTests`' `aPauseBeforeTheSendSendsNothing` and `keepingTheAppOnThisMacBeforeTheSendSendsNothing` included).
- [ ] **Step 5: Commit**

```bash
git add Packages/SkaldCore/Sources/SkaldCore/Pipeline/CheckPipeline.swift \
  Packages/SkaldCore/Sources/SkaldCore/Pipeline/ClaudeStatus.swift \
  Packages/SkaldCore/Tests/SkaldCoreTests/ClaudeFailureTests.swift
git commit -m "Fall back and back off when Claude can't answer, and report it"
```

---

### Task 9: The menu bar shows when checks use Claude

> Superseded in review (commits `6ca8fdc`, `7035de6`): there is no `LoggedEngine`; the pipeline reports each sent request's outcome through `onClaudeRequest` and `ClaudeTypingLog` records it. While a request can leave, the menu's first line is the Claude line and a failure is a second line. "Turn On" sets This Mac only for an app that is off by default or while Claude typing is on.

**Safety boundary: showing what is sent; this task also turns the path on in the app. Per-task review.**

**Depends on:** Task 8 (the previous task; `ClaudeStatus`, `resetClaude()`); Task 5 (`claudeTypingLanguages`, `onDevice`); Task 4 (`AppMode`); Task 1 (`ClaudeRequestOptions.typing`)

**Files:**
- Modify: `Skald/StatusItemController.swift` (`StatusState`, `image(sendingToClaude:)`, `show(_:sendingToClaude:)`, the menu)
- Modify: `Skald/CompositionRoot.swift` (the pipeline's `claude:` factory through `LoggedEngine`; consume `claudeStatus`; `refreshStatus`; a `claudeKeyChanged` pipeline command)
- Modify: `Skald/SettingsModel.swift:131-135` (`onClaudeKeyChange: (() -> Void)?`, called after a key is saved or removed)
- Modify: `Skald/Log.swift` (`static let claude = Logger(subsystem: SkaldCore.bundleID, category: "claude")`)
- Create: `Skald/ClaudeTypingLog.swift`
- Create: `design/menubar-cloud.svg`; Modify: `design/render` (two more `rsvg-convert` lines into `SkaldMenuBarCloud.imageset`)
- Create: `Skald/Assets.xcassets/SkaldMenuBarCloud.imageset/Contents.json` (as `SkaldMenuBar.imageset`'s, with the new file names), `Skald/Assets.xcassets/SkaldMenuBarCloud.imageset/SkaldMenuBarCloud@1x.png`, `Skald/Assets.xcassets/SkaldMenuBarCloud.imageset/SkaldMenuBarCloud@2x.png`
- Test: `SkaldTests/StatusTitleTests.swift`; Create `SkaldTests/ClaudeTypingLogTests.swift`

**Interfaces:**
- Consumes: `CheckPipeline.claudeStatus`, `resetClaude()` (Task 8); `EngineRouter.claudeTypingLanguages`, `onDevice(_:)` (Task 5); `AppMode`, `Settings.mode(app:)` (Task 4); `ClaudeEngine(…, options: .typing)` (Task 1).
- Produces:
  ```swift
  struct ClaudeFallback: Equatable { let language: Language; let route: TypingRoute }
  enum StatusState: Equatable {
      case onThisMac, usingClaude([Language]), claudeTrouble(ClaudeTrouble, fallbacks: [ClaudeFallback])
      case paused(until: Date), spellingOnly(UnavailableReason), noAccessibility
      static func resolve(trusted: Bool, pausedUntil: Date?, now: Date, apple: UnavailableReason?, thermalPaused: Bool,
                          claude: ClaudeStatus, claudeLanguages: [Language], fallbacks: [ClaudeFallback]) -> StatusState
      static let glyphName = "SkaldMenuBar", cloudGlyphName = "SkaldMenuBarCloud"
      func image(sendingToClaude: Bool) -> NSImage?
  }
  nonisolated final class ClaudeTypingLog: Sendable {
      func record(_ outcome: Result<String, EngineFailure>) -> Int      // logs `line` with privacy .public, returns the count
      static func line(_ count: Int, _ outcome: Result<String, EngineFailure>) -> String
  }
  nonisolated struct LoggedEngine: Engine { init(_ inner: any Engine, log: ClaudeTypingLog) }
  ```
- Both are `nonisolated`, as `AppSwitches` and `KeychainStore` are: the app target defaults to MainActor isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION`), and the pipeline's actor calls them.
- Rank: no Accessibility > paused > `claudeTrouble` (a trouble and a non-empty `claudeLanguages`) > `usingClaude` (`sending` and a non-empty `claudeLanguages`) > `spellingOnly` (Apple, then thermal) > `onThisMac`. `fallbacks` = `claudeTypingLanguages` with `onDevice` of each.
- Glyph: the cloud form exactly while `ClaudeStatus.sending`; both forms are templates described by the title.
- Menu, top down: the title; a separator; "Keep ‹App› on This Mac" (checkmark when `.thisMacOnly`; toggles to `.on` or `.thisMacOnly`; shown when there is a frontmost app whose mode isn't `.off`); Pause/Resume; Turn Off/On; Grant Accessibility Access when needed; a separator; Settings; Quit.
- Log line: `typing request N: answered`, or `typing request N: ` plus `ClaudeTrouble`'s raw value, or `cancelled`. Nothing else.
- Wiring: the factory is `{ model in LoggedEngine(ClaudeEngine(model: model, apiKey: { keychain.read() }, transport: transport, options: .typing), log: claudeLog) }`; `onClaudeKeyChange` sends a command that calls `pipeline.resetClaude()`.

- [ ] **Step 1: Write the failing tests.** `StatusTitleTests` (put its functions in `struct StatusTitleTests`):

```swift
@Test func eachStateHasItsTitle()      // .onThisMac → "Checking on this Mac"; the other v1 titles as before
@Test func claudeStatesNameTheLanguagesAndWhatTheyFellBackTo() {
    #expect(StatusState.usingClaude([.nl, .fr]).title() == "Dutch and French checks use Claude")
    #expect(StatusState.usingClaude([.nl]).title() == "Dutch checks use Claude")
    #expect(StatusState.usingClaude([.fr]).title() == "French checks use Claude")
    #expect(StatusState.claudeTrouble(.unreachable, fallbacks: [.init(language: .nl, route: .spellingOnly(.languageOff)), .init(language: .fr, route: .off)]).title()
        == "Claude unreachable: Dutch is spelling only, French isn't checked while typing")
    #expect(StatusState.claudeTrouble(.keyRejected, fallbacks: [.init(language: .nl, route: .model)]).title()
        == "Claude has no valid API key: Dutch is checked on this Mac")
    #expect(StatusState.claudeTrouble(.rateLimited, fallbacks: []).title() == "Claude is limiting requests")
    #expect(StatusState.claudeTrouble(.declined, fallbacks: []).title() == "Claude declined a paragraph")
}
@Test func claudeTroubleRanksBelowPauseAndAboveClaudeAndApple()
// paused + trouble → .paused; trouble + sending + apple off → .claudeTrouble; sending + apple off → .usingClaude([.nl, .fr]);
// sending with claudeLanguages [] → .spellingOnly(apple); trouble with claudeLanguages [] and nothing else → .onThisMac
@Test func theCloudGlyphShowsOnlyWhileSending()
// image(sendingToClaude: true).tiffRepresentation == NSImage(named: cloudGlyphName).tiffRepresentation; false → glyphName's;
// both isTemplate; the two differ
```
Update `everyStateShowsTheMenuBarGlyph…` to `image(sendingToClaude: false)` and the new states. `ClaudeTypingLogTests`:
```swift
@Test func eachLineCountsARequestAndNamesItsOutcomeOnly()
// line(3, .success("Ik heb de fix nagekeken")) == "typing request 3: answered";
// line(4, .failure(.unavailable(.claudeKeyRejected))) == "typing request 4: keyRejected"; line(5, .failure(.cancelled)) == "typing request 5: cancelled"
@Test func theLoggedEngineCountsEveryRequestAndAnswersAsTheInnerOne() async throws   // two runs → count 2; answers unchanged
```

- [ ] **Step 2: Run, expect failure.** App suite → compile failure.
- [ ] **Step 3: Draw and render the glyph.** `design/menubar-cloud.svg`: the menubar glyph with a small cloud at its top right, set off by the same gap as the check mark. Run `design/render` (needs `rsvg-convert`; if missing, stop and report, never install ad hoc). Check the two PNGs into the new image set. `design/render` re-renders every icon: afterwards `git restore` any PNG outside the new image set that shows as modified.
- [ ] **Step 4: Implement** the interfaces and wiring.
- [ ] **Step 5: Run, expect pass.** App suite.
- [ ] **Step 6: Commit**

```bash
git add Skald/StatusItemController.swift Skald/CompositionRoot.swift Skald/SettingsModel.swift Skald/Log.swift \
  Skald/ClaudeTypingLog.swift design/menubar-cloud.svg design/render \
  Skald/Assets.xcassets/SkaldMenuBarCloud.imageset/Contents.json \
  Skald/Assets.xcassets/SkaldMenuBarCloud.imageset/SkaldMenuBarCloud@1x.png \
  Skald/Assets.xcassets/SkaldMenuBarCloud.imageset/SkaldMenuBarCloud@2x.png \
  SkaldTests/StatusTitleTests.swift SkaldTests/ClaudeTypingLogTests.swift
git commit -m "Show a cloud in the menu bar while checks go to Claude"
```

---

### Task 10: Settings for Claude while typing

**Depends on:** Task 9 (the previous task; order only); Task 4 (`claudeTyping`, `claudeLanguages`)

**Files:**
- Modify: `Skald/Settings/LanguagesPane.swift`, `Skald/Settings/EnginesPane.swift:13`, `Skald/SettingsModel.swift`
- Test: `SkaldTests/SettingsModelTests.swift`

**Interfaces:**
- Consumes: `Settings.claudeTyping`, `claudeLanguages` (Task 4). `claudeTypingModel` stays a stored setting with no field in Settings.
- Produces:
  ```swift
  extension SettingsModel {
      @discardableResult func setClaudeTyping(_ on: Bool) -> Bool   // false and no change when turning on without a stored key
      func claudeLanguage(_ language: Language) -> Binding<Bool>
  }
  ```
- Copy, fixed: section "Claude while typing"; switch "Check Dutch and French with Claude while typing" (disabled without a key, with "Store a Claude API key under Engines to turn this on."); ticks "Dutch", "French" (disabled while the switch is off); text "While you type Dutch or French, Skald sends the paragraph you are typing in, and nothing else, to Anthropic's Claude API with your key. English stays on this Mac, and so does every app kept on This Mac only. The menu bar icon shows a cloud while checks go to Claude." Per language, the switches read "Check while typing on this Mac" and "Model checks on this Mac (grammar and spelling)"; for a language Claude takes, under them: "Claude checks ‹Dutch› while typing. These switches apply when ‹Dutch› is back on this Mac: in apps kept on This Mac only, and when Claude can't answer." Engines: the first section's text becomes "Checking while typing runs on this Mac, unless you turn on Claude for Dutch and French under Languages." Nothing else in the Engines pane changes.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func turningClaudeTypingOnNeedsAStoredKey() throws
// no key: setClaudeTyping(true) == false, settings.claudeTyping == false; after saveClaudeKey("sk-test"): true, claudeTyping == true
@Test func theClaudeSwitchNeverRewritesTheOnDeviceSwitches() throws
// key stored; record typingChecks and modelChecks; switch on, untick French, switch off: both maps equal the recorded ones
```
- [ ] **Step 2: Run, expect failure.** App suite.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect pass.** App suite.
- [ ] **Step 5: Commit**

```bash
git add Skald/Settings/LanguagesPane.swift Skald/Settings/EnginesPane.swift Skald/SettingsModel.swift \
  SkaldTests/SettingsModelTests.swift
git commit -m "Add the Claude while typing switch to Settings"
```

---

### Task 11: The card's Claude label and the panel's This Mac only line

**Depends on:** Task 10 (the previous task; order only); Task 7 (`Issue.engine`); Task 5 (`.keptOnThisMac`, `PanelSession`'s app)

**Files:**
- Modify: `Skald/Overlay/CardOutcome.swift:89-114` (`byClaude`), `Skald/Overlay/IssueCard.swift:162-202` (the label)
- Modify: `Skald/Panel/PanelController.swift:36-56` (`keptOnThisMac`, `keptNote`), `Skald/Panel/PanelView.swift` (the line), `Skald/CompositionRoot.swift` (sets `keptOnThisMac` when the frontmost app's mode is `.thisMacOnly`)
- Modify: `SkaldTests/Support/IssueFixture.swift` (`engine: EngineKind? = nil`)
- Test: `SkaldTests/CardOutcomeTests.swift`, `SkaldTests/PanelReplaceTests.swift`

**Interfaces:**
- Consumes: `Issue.engine` (Task 7); `.keptOnThisMac` routing (Task 5).
- Produces: `IssueCardModel.byClaude: Bool` (`issue.engine == .claude`), shown as a small secondary "Claude" at the card's top right; `PanelOpening.keptOnThisMac: String?` (the app's name); `PanelController.keptNote: String?` == "Skald keeps ‹App› on this Mac, so the panel offers This Mac only.", shown like the clipboard label, never blocking a run.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func aCardForAnIssueClaudeFoundSaysClaude()
// engine .claude → byClaude; engine .thisMac → false; a spelling issue → false
@Test func anAppKeptOnThisMacSaysWhyThePanelOffersThisMacOnly()
// open with keptOnThisMac "Notes": keptNote == "Skald keeps Notes on this Mac, so the panel offers This Mac only."; nil → nil; the phase is not .blocked
```
- [ ] **Step 2: Run, expect failure.** App suite.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect pass.** App suite.
- [ ] **Step 5: Commit**

```bash
git add Skald/Overlay/CardOutcome.swift Skald/Overlay/IssueCard.swift Skald/Panel/PanelController.swift \
  Skald/Panel/PanelView.swift Skald/CompositionRoot.swift SkaldTests/Support/IssueFixture.swift \
  SkaldTests/CardOutcomeTests.swift SkaldTests/PanelReplaceTests.swift
git commit -m "Label Claude's cards and say why a kept app's panel stays on this Mac"
```

---

### Task 12: Changelog and documentation

**Depends on:** Task 11 (the previous task); Tasks 3, 9 and 10 (what it documents)

**Files:**
- Modify: `CHANGELOG.md` (`## [Unreleased]`, line 19), `README.md:20`, `Eval/README.md` ("What missed")

- [ ] **Step 1: CHANGELOG.** Under `### Added`:
  - "Dutch and French can be checked by Claude while you type: turn on Settings > Languages > Claude while typing, with your own Claude API key. Only the paragraph you are typing in is sent, English always stays on your Mac, and the menu bar icon shows a cloud while checks go to Claude. A card says when Claude found the issue. When Claude can't answer, Skald falls back to your on-device settings and the menu says why."
  - "Each app can be On, This Mac only or Off, in Settings > Apps or with the menu's Keep on This Mac. Nothing you type in an app kept on this Mac goes to Claude, and the panel offers only This Mac there."

  Under `### Fixed`: "A French or Dutch fix such as "Tout les" → "Tous les" is no longer dropped because the word also exists in English."

  In the existing unreleased entry "Optional remote engines for the panel…", replace "Checking while you type always stays on your Mac." with "Checking while you type stays on your Mac unless you turn on Claude for Dutch and French."
- [ ] **Step 2: README.** Replace "Checks while you type always stay on your Mac." with "Checks while you type stay on your Mac, unless you turn on Claude for Dutch and French in Settings > Languages: then the paragraph you are typing in goes to Anthropic's Claude API, the menu bar icon shows a cloud, and apps you keep on This Mac only still send nothing."
- [ ] **Step 3: Eval/README.** Under "What missed", after the `fr-h07` line: "Fixed by stage 1 of the upgrade (2026-11-21): a word the paragraph's own dictionary accepts is no longer a borrowed word because English has it too. `fr-h07` and every case in this list are exposed, so their results after the fix prove nothing."
- [ ] **Step 4: Check.** `/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'` passes (the changelog tool reads `CHANGELOG.md`).
- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md README.md Eval/README.md
git commit -m "Document Claude checks while typing"
```

---

## Final verification (controller, on the last commit)

Outside the sandbox, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:

- Core, Platform and App suites; `/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'`.
- `mise exec -- xcodegen generate`, a Release and a Debug build into `build/dd.noindex`, then `scripts/tests/test-verify-app build/dd.noindex/Build/Products/Release/Skald.app build/dd.noindex/Build/Products/Debug/Skald.app` and `scripts/verify-app build/dd.noindex/Build/Products/Release/Skald.app`.
- `rg -n 'print\(|Log\.\w+\.\w+\(' Skald Packages/SkaldCore/Sources Packages/SkaldPlatform27/Sources/SkaldPlatform27` shows no new line that interpolates a text, an issue word or the key.

Report totals as passed/total.

## Memory, before and after (controller)

Outside the sandbox (`open` needs it; Michael approves the prompt). Each step replaces `/Applications/Skald.app`; leave the new Release build installed and say so.

1. Sample text: `/usr/bin/python3 -c 'import json; [print(json.loads(l)["text"]) for l in open("Eval/seed.jsonl")]' > build/memory-sample.txt` (synthetic, 36 paragraphs in three languages).
2. For the baseline (`build/baseline/Skald.app`) and then the new Release build (`build/dd.noindex/Build/Products/Release/Skald.app`), Claude switch off as shipped:
   - `pkill -x Skald`; `rm -rf /Applications/Skald.app && ditto <build> /Applications/Skald.app`; `open /Applications/Skald.app`; wait 60 s; `/usr/bin/footprint -p Skald` → **idle**.
   - `open -a TextEdit build/memory-sample.txt`; wait 60 s (the caret's paragraph checked, the rest spelled); `/usr/bin/footprint -p Skald` → **after checking**. Close the document without saving.
3. Record the four "Footprint" figures with the build commits in the PR description under "Memory"; until the PR exists, in `.superpowers/upgrade-evidence/memory.md` (untracked). Michael adds the switch-on figure after the gate run (below).

## Owed: the gate run (Michael)

**Not a task for an implementer. No agent runs these commands.** It needs the new, separate, revocable key (Decision 2) and must pass before the Claude switch is turned on for daily use (spec, "The gate": stage 1 ships with v1). The total of every `--max-cost` passed below must not exceed **$5**; the planned caps sum to $4.05, which leaves $0.95 for one re-run. A claude run never overwrites: a re-run needs a new `--out` path, and `--max-cost` caps one run, not the total.

```sh
cd ~/Code/skald-feat-skald-upgrade
git switch --detach 814149a                      # the eval modes, with the guard as it was before the fix
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
read -s SKALD_EVAL_CLAUDE_KEY && export SKALD_EVAL_CLAUDE_KEY
mkdir -p build/eval
cat Eval/seed.jsonl Eval/tuning.jsonl > build/eval/tuning-part.jsonl
head -1 Eval/seed.jsonl > build/eval/probe.jsonl
E="swift run --package-path Packages/SkaldPlatform27 skald-eval"

# 0. Is the request refused with fallbacks? One paragraph.
$E --set build/eval/probe.jsonl --mode claude --claude-model claude-haiku-5-5 --fallbacks on --max-cost 0.05 --out build/eval/probe-fallbacks.jsonl
# 1-2. Settle thinking on the tuning part only, effort low.
$E --set build/eval/tuning-part.jsonl --mode claude --claude-model claude-haiku-5-5 --thinking off --max-cost 1.00 --out build/eval/tuning-off.jsonl
$E --set build/eval/tuning-part.jsonl --mode claude --claude-model claude-haiku-5-5 --thinking on  --max-cost 1.50 --out build/eval/tuning-on.jsonl
# 3. Grade the held-out set once, with the settled request, guard on (THE GATE).
$E --set Eval/heldout.jsonl --mode claude --claude-model claude-haiku-5-5 --thinking <off|on> --max-cost 1.50 --out build/eval/heldout-claude.jsonl
# 4. Guard off, for diagnosis: a replay of the same answers, no spend.
$E --set Eval/heldout.jsonl --mode replay --outputs build/eval/heldout-claude.jsonl.raw.jsonl --guard off
unset SKALD_EVAL_CLAUDE_KEY
git switch feat/skald-upgrade
# 5. Both sets once more with the fixed guard: replays, no spend. French with and without fr-h07.
$E --set build/eval/tuning-part.jsonl --mode replay --outputs build/eval/tuning-<off|on>.jsonl.raw.jsonl
$E --set Eval/heldout.jsonl --mode replay --outputs build/eval/heldout-claude.jsonl.raw.jsonl
grep -v '"id":"fr-h07"' Eval/heldout.jsonl > build/eval/heldout-without-fr-h07.jsonl
$E --set build/eval/heldout-without-fr-h07.jsonl --mode replay --outputs build/eval/heldout-claude.jsonl.raw.jsonl
```

- **Settling the request.** Thinking: of steps 1 and 2, keep the setting that meets the bar on the tuning part, and the faster (lower p90) if both do. Fallbacks: if step 0 fails (a request error, NO VERDICT), it stays off. If it is accepted, it still stays off: the API reference says Claude Haiku 5.5 has no server-side fallback and ignores `"default"`; turning it on is Michael's call. The change is one line, `ClaudeRequestOptions.typing`, plus `typingRequestShape`'s expected body; commit "Settle the typing request on the tuning run".
- **Pass, per language, for Dutch and French on the held-out set, guard on (step 3):** precision at least 0.95, at most one clean paragraph flagged, recall at least 0.90, p90 latency under 2 s (the tool's verdict for `--mode claude`). English's line is informational; the tool's exit status counts it too.
- **Cost:** the summary's "a month at 500 checks a day" figure from step 3.
- **Stop and bring it to Michael** if Dutch or French misses the bar, if p90 is 2 s or more, or if the monthly figure is above $5.
- **Record in `Eval/README.md`**, a new section "Claude path (upgrade stage 1)": date, macOS version, model id, the request (effort low, thinking, fallbacks), the gate commit; a table per run (steps 1–3: set, guard, precision, recall, clean flagged, p50/p90, verdict, tokens, cost, cost per check, monthly at 500 a day; step 0's outcome); the guard-off diagnosis (step 4); the re-grade with the fixed guard (step 5), French with and without `fr-h07`, noting that `fr-h07` and the "What missed" cases are exposed; the total spent against the $5 limit. Commit "Record the Claude gate run".
- **Memory with the switch on:** with the key in Settings and the switch on, the "after checking" step of "Memory, before and after"; add the figure to the PR.

### Michael's manual checks (spec, "Stage 1 verification")

With the switch on, type Dutch and French in Notes, Zen and Slack: the glyph shows the cloud only there. A "This Mac only" app and a secure field send nothing: `/usr/bin/log stream --predicate 'subsystem == "com.michaelrigart.skald" AND category == "claude"'` shows no new `typing request` line while typing in them. With the network off, the menu's first line says "Claude unreachable: …".

## Finishing (controller)

> Superseded 2026-11-21 (Michael): stage 1 is merged into `feat/skald-v1` locally once the pre-merge review approves, and ships with PR #1; it gets no PR of its own.

- Push `feat/skald-upgrade`; open a draft PR (`merge-request` skill) into `feat/skald-v1` while PR #1 is open, else `main`. Its body names the gate commit (Task 2), lists the Rulings, the Memory figures, and states that it leaves draft only after "Owed: the gate run" passes and is recorded.
- The spec's **Status** stays `In progress`, citing stage 1's PR: it also holds stage 2, which is not built. At the final pre-merge commit only this plan is marked completed (`Implemented`, citing the PR; "do not run this plan again").
- The final report gives `wt-rm feat/skald-upgrade` for once it is merged or abandoned.
