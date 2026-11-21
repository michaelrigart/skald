# Evaluation set

Synthetic paragraphs in Michael's register (work email, chat and tech notes, in Belgian usage) for
English, Dutch and French. The company names Brightline and Northwind are fictional. No case holds
customer content, personal data or a real company name.

| File | Holds | en | nl | fr |
|---|---|---|---|---|
| `seed.jsonl` | the spike's paragraphs (the design spec's appendix) | 12 (4 clean) | 12 (4 clean) | 12 (4 clean) |
| `tuning.jsonl` | new paragraphs the edit guard may be tuned on | 20 (7 clean) | 20 (7 clean) | 20 (7 clean) |
| `heldout.jsonl` | new paragraphs that only grade | 20 (7 clean) | 20 (7 clean) | 20 (7 clean) |
| all | | 52 (18 clean) | 52 (18 clean) | 52 (18 clean) |

Each line holds `id`, `lang`, `text` and `ref`, the reference correction (equal to `text` for a
clean paragraph). The tuning part is `seed.jsonl` plus `tuning.jsonl`. Every new case carries
`"reviewed": false` until Michael has reviewed it. **All results below are provisional until
Michael reviews the data.**

## Running

From the repository root, outside any agent sandbox:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p build/eval
swift run --package-path Packages/SkaldPlatform27 skald-eval --set Eval/heldout.jsonl --mode model --out build/eval/heldout-model.jsonl
swift run --package-path Packages/SkaldPlatform27 skald-eval --set Eval/heldout.jsonl --mode spelling --out build/eval/heldout-spelling.jsonl
cat Eval/seed.jsonl Eval/tuning.jsonl > build/eval/tuning-part.jsonl
```

`skald-eval --set <path> --mode model|spelling|claude|replay [--guard on|off] [--out <path>]
[--claude-model <id>] [--max-cost <dollars>] [--thinking on|off] [--fallbacks on|off]
[--outputs <file.jsonl>]` prints the cases it got wrong, then each language's scores and the bar's
verdict. A language with a failed request gets no verdict, which counts as a miss. It exits 0 when
every language passes and 1 when any fails or has no verdict. `--guard off` skips the edit guard,
for diagnosis only. Outputs stay under `build/`, which is not tracked. No mode overwrites a
file: if `--out`, or `<out>.raw.jsonl` on the model path (model and replay), already exists, the
run stops with exit 2 before running, so pick a new `--out` for each run.

The four modes:

- **model:** Apple's on-device model, as below.
- **spelling:** the system spell checker, as below.
- **claude:** each case is sent to Claude as the app's typing request, then judged like the model
  path. It needs `--claude-model` (`claude-haiku-5-5`, `claude-sonnet-5-5` or `claude-opus-5-5`;
  any other id has no price and is refused), `--max-cost` and `--out`, and the key in
  `SKALD_EVAL_CLAUDE_KEY`; no other variable is read, and a missing key stops the run before any
  request. `--thinking on|off` and `--fallbacks on|off` change the request, and both default to
  off, which is the app's typing request. `claude-sonnet-5-5` and `claude-opus-5-5` reject a
  request with thinking disabled (a 400), so for them `--thinking off`, and leaving it out,
  is refused at the start: pass `--thinking on`. The latency bar is p90 under 2 s.
- **replay:** the answers recorded in `--outputs` (a `.raw.jsonl` file, or the proxy runs'
  `id`/`output` lines) go through the guard as if the engine had given them, in no time and at no
  cost. A case without a recorded answer is a request error. This is how guard-off runs and later
  re-grades are made, with no latency bar.

A claude run writes three files: `--out` (the graded outputs), `<out>.raw.jsonl` (each answer as
cleaned, before the guard, replayable) and `<out>.usage.jsonl` (one line per request with its
tokens, cost and the running total). All three are created before the first request, and the run
stops with exit 2 and sends nothing if one of them already exists (a re-run never overwrites an
earlier paid run's record) or cannot be created, such as in a missing directory. Each case's lines
are appended as the case finishes, so an interrupted run keeps what it paid for; a failed write
stops the run. Each request also prints its usage line on stderr, and the run ends with a summary
line: requests, tokens, cost against the limit, the cost of a check and of a month at 500 checks a
day.

`--max-cost` (above 0, at most 5) is a strict bound. A request is sent only when its ceiling
(the body's bytes as input tokens, plus the 4096 output tokens the request allows) fits in what is
left, and a request whose answer carries no usage, lost to an error or a timeout, is charged that
ceiling, and its usage line holds the ceiling as the cost with null token counts. Cases left once
the limit is reached are request errors, and the summary says the run stopped at the cost limit.

The runner takes each case through the app's own path, one case at a time:

- **model:** Apple's on-device model (a check request, its output cleaned) → `judgeWhole` with the
  detected language of the output → `resolve` with the system's word facts and the on-device
  confirmer.
- **spelling:** `NSSpellChecker` flags → `resolve` without a confirmer.

Language detection runs without a previous language. A missing or wrong detection is counted, and
the case runs in its own language. Latency is wall-clock time for the whole path of one case. p90 is
the ⌊0.9 n⌋-th fastest latency (the 18th of 20), as in the spike's scorer. Scoring compares token
edits with the single reference, also as in the spike.

The bar (design spec, Verification), per language on the held-out part: on the model path,
precision at least 0.95, at most one clean paragraph flagged, recall at least 0.90 and p90 under
1 s; spelling only, precision at least 0.95.

## Tuning

Only the edit guard's rules changed, on the tuning part only. Review then narrowed three of them,
because they also dropped real fixes (commits "Tune the edit guard on the evaluation set" and
"Narrow the compound, abbreviation and neighbour rules"). Each rule has its own row in the guard's
outcome table. The shipped rules:

- A paragraph's only sentence keeps its lowercase start, unless it ends in a period.
- A listed function word or contraction fragment ("didn", "ve") never counts as a misspelling.
- Two words are near-homophones only when one stretch of at most two letters differs ("opkuisen" →
  "opruimen" is a replacement).
- A different content word with an unknown lemma is a replacement, also when it replaces a
  preposition. This makes "voorvallen" → "voorkomen" a drop, as in the spec's table.
- A model edit kept only because it swaps function words is dropped when it sits next to an edit
  dropped as a rewrite (at most one unchanged token apart). Content-word misspelling fixes and
  capital fixes are never dropped this way.
- A spelling guess that splits a word at a space into content words ("runbook" → "run book") is
  dropped. A restored apostrophe ("cant" → "can't") is not a split, and the model's splits are
  judged as fixes.
- A word of two or more letters without a vowel is an abbreviation and never touched, unless the
  fix keeps its letters as typed and adds at most two letters, and fewer than the word has
  ("vpn" → "van", "vpn" → "VPN", "pls" → "please" and "ds" → "dans" are dropped; "th" → "the" and
  "frm" → "from" are fixes). These bounds came after the second grading. None of the 231 edits the
  guard judged on the tuning part and the held-out part has a vowel-less word whose fix keeps its
  letters and either adds three or more or adds as many as the word has, so no grading changes.

No result was discarded for changing too much, so `maxChangeShare` stays at 0.4.

Tuning part (32 cases per language), guard on. "Tuned" is the first commit and "shipped" the
narrowed guard; the narrowing brings back one French false alarm ("saurai" → "serai" next to a
dropped rewrite).

| Mode | Language | Precision before → tuned → shipped | Recall | Clean flagged before → tuned → shipped |
|---|---|---|---|---|
| Model | en | 0.91 (30/33) → 0.97 (30/31) → 0.97 (30/31) | 0.91 throughout | 1/11 → 1/11 → 1/11 |
| Model | nl | 0.76 (22/29) → 0.96 (22/23) → 0.96 (22/23) | 0.92 throughout | 2/11 → 0/11 → 0/11 |
| Model | fr | 0.88 (22/25) → 0.96 (22/23) → 0.92 (22/24) | 0.96 throughout | 2/11 → 0/11 → 1/11 |
| Spelling | en | 0.43 (6/14) → 0.67 (6/9) → 0.67 (6/9) | 0.18 throughout | 4/11 → 2/11 → 2/11 |
| Spelling | nl | 1.00 (7/7) throughout | 0.29 throughout | 0/11 throughout |
| Spelling | fr | 1.00 (3/3) throughout | 0.13 throughout | 0/11 throughout |

Known losses the guard accepts: a preposition replaced by a content word that is not a
near-homophone is dropped, so "I went threw the logs" → "through" is lost.

## Held-out results

Current: graded on 2026-11-02 on macOS 27.2, with the shipped guard. No language detection missed
and no request failed.

| Mode | Language | Precision | Recall | Clean flagged | p50 / p90 | Verdict |
|---|---|---|---|---|---|---|
| Model | en | 1.00 (17/17) | 1.00 (17/17) | 0/7 | 425 / 485 ms | pass |
| Model | nl | 0.91 (10/11) | 0.71 (10/14) | 0/7 | 392 / 483 ms | fail: precision, recall |
| Model | fr | 0.87 (13/15) | 0.81 (13/16) | 0/7 | 386 / 450 ms | fail: precision, recall |
| Spelling | en | 0.67 (6/9) | 0.35 (6/17) | 1/7 | 2 / 18 ms | fail: precision |
| Spelling | nl | 1.00 (7/7) | 0.50 (7/14) | 0/7 | 1 / 15 ms | pass |
| Spelling | fr | 0.67 (2/3) | 0.12 (2/16) | 1/7 | 1 / 13 ms | fail: precision |

Re-run for acceptance on 2026-11-06 on macOS 27.2, same guard, nothing tuned: every case scored as
in the current grading (same precision, recall and clean-flagged figures, same verdicts), so the
defaults below stand. Latencies (p50 / p90): model en 448 / 506 ms, nl 417 / 502 ms, fr 400 /
440 ms; spelling 2 / 20–28 ms. Graded once more the same day after the final review's guard
changes (British spelling first, a British/American variant swap dropped; found by review, not
tuned on data): every output identical to the run before, case by case, in both modes.

Superseded: the first grading, also on 2026-11-02 on macOS 27.2. It was graded before review
narrowed three over-broad rules; the second grading describes the shipped guard. Every case scored
the same in both gradings; only the latencies differ.

| Mode | Language | Precision | Recall | Clean flagged | p50 / p90 | Verdict |
|---|---|---|---|---|---|---|
| Model | en | 1.00 (17/17) | 1.00 (17/17) | 0/7 | 459 / 510 ms | pass |
| Model | nl | 0.91 (10/11) | 0.71 (10/14) | 0/7 | 428 / 501 ms | fail: precision, recall |
| Model | fr | 0.87 (13/15) | 0.81 (13/16) | 0/7 | 396 / 464 ms | fail: precision, recall |
| Spelling | en | 0.67 (6/9) | 0.35 (6/17) | 1/7 | 2 / 19 ms | fail: precision |
| Spelling | nl | 1.00 (7/7) | 0.50 (7/14) | 0/7 | 2 / 17 ms | pass |
| Spelling | fr | 0.67 (2/3) | 0.12 (2/16) | 1/7 | 2 / 29 ms | fail: precision |

### Default changes

From the current grading, provisional until Michael reviews the data:

- **Dutch:** model checks are off by default (model precision 0.91). Spelling only passes, so
  checking while typing stays on, as spelling only.
- **French:** model checks and checking while typing are off by default (model precision 0.87,
  spelling-only precision 0.67). The panel still works in French.
- **English:** no change. Its spelling-only miss has no effect while the model path passes.
- The recall misses (Dutch 0.71, French 0.81) change no default; they go in the merge request.

### What missed

A diagnostic run with the guard off, made after the first grade, separates the model's misses from
the guard's. Nothing was tuned on held-out data; the narrowing came from review with synthetic
cases.

- **False alarms the guard kept:**
  - `nl-h12`: "gecancelled" → "geannuleerd". A misspelled original keeps any replacement, so the
    borrowed word was replaced.
  - `fr-h13`: "au nouvel environement" → "à la nouvelle environnement", one edit whose misspelling
    fix carried a wrong gender change.
  - `fr-h11`: "sa" → "ce" scores as a false alarm and a miss, but it is as correct as the
    reference's "ça". The scorer knows one reference only.
- **Misses:**
  - The model proposed no fix for `nl-h03` ("gebeurt") or `nl-h06` ("Zowiezo").
  - The guard dropped `fr-h07` "Tout" → "Tous" as a borrowed word, because "tout" is also an
    English word.
    Fixed by stage 1 of the upgrade (2026-11-21): a word the paragraph's own dictionary accepts
    is no longer a borrowed word because English has it too, when the fix is a close native
    form of it. `fr-h07` and every case in this list are exposed, so their results after the fix
    prove nothing.
  - The guard dropped `nl-h07` "hebben" → "heeft", which came in one edit with "beslist" →
    "besloten".
- **Spelling only:**
  - "wich" → "with", a wrong first guess.
  - "Brightline" → "Brighten" and "Northwind" → "Northland", names at the start of a sentence.
  - "kot" → "mot", Belgian French.
