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

`skald-eval --set <path> --mode model|spelling [--guard on|off] [--out <path>]` prints the cases it
got wrong, then each language's scores and the bar's verdict. A language with a failed request gets
no verdict, which counts as a miss. It exits 0 when every language passes and 1 when any fails or
has no verdict. `--guard off` skips the edit guard, for diagnosis only. Outputs stay under `build/`,
which is not tracked.

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
  dropped as a rewrite (at most one unchanged token apart). Misspelling, accent, agreement and
  capital fixes are never dropped this way.
- A spelling guess that splits a word at a space into content words ("runbook" → "run book") is
  dropped. A restored apostrophe ("cant" → "can't") is not a split, and the model's splits are
  judged as fixes.
- A word of two or more letters without a vowel is an abbreviation and never touched, unless the
  fix keeps its letters as typed and adds at most two ("vpn" → "van", "vpn" → "VPN" and "pls" →
  "please" are dropped; "th" → "the" is a fix). The two-letter bound came after the second grading;
  none of the 231 edits the guard judged on the tuning part and the held-out part has a vowel-less
  word that a fix keeps while adding three or more letters, so no grading changes.

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
  - The guard dropped `nl-h07` "hebben" → "heeft", which came in one edit with "beslist" →
    "besloten".
- **Spelling only:**
  - "wich" → "with", a wrong first guess.
  - "Brightline" → "Brighten" and "Northwind" → "Northland", names at the start of a sentence.
  - "kot" → "mot", Belgian French.
