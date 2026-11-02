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
got wrong, then each language's scores and the bar's verdict. It exits 0 when every language passes
and 1 when any fails. `--guard off` skips the edit guard, for diagnosis only. Outputs stay under
`build/`, which is not tracked.

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

Only the edit guard's rules changed, on the tuning part only (commit "Tune the edit guard on the
evaluation set"). Each rule has its own row in the guard's outcome table.

- A paragraph's only sentence keeps its lowercase start.
- A listed function word or contraction fragment ("didn", "ve") never counts as a misspelling.
- Two words are near-homophones only when one stretch of at most two letters differs ("opkuisen" →
  "opruimen" is a replacement).
- A different content word with an unknown lemma is a replacement, also when it replaces a
  preposition. This makes "voorvallen" → "voorkomen" a drop, as in the spec's table.
- A model edit next to an edit dropped as a rewrite (at most one unchanged token apart) is dropped
  with it.
- A guess that splits a word into content words ("runbook" → "run book") is dropped.
- A word of two or more letters without a vowel ("vpn", "gsm") is an abbreviation and never
  touched.

No result was discarded for changing too much, before or after, so `maxChangeShare` stays at 0.4.

Tuning part (32 cases per language), guard on:

| Mode | Language | Precision before | Precision after | Recall before → after | Clean flagged before → after |
|---|---|---|---|---|---|
| Model | en | 0.91 (30/33) | 0.97 (30/31) | 0.91 → 0.91 | 1/11 → 1/11 |
| Model | nl | 0.76 (22/29) | 0.96 (22/23) | 0.92 → 0.92 | 2/11 → 0/11 |
| Model | fr | 0.88 (22/25) | 0.96 (22/23) | 0.96 → 0.96 | 2/11 → 0/11 |
| Spelling | en | 0.43 (6/14) | 0.67 (6/9) | 0.18 → 0.18 | 4/11 → 2/11 |
| Spelling | nl | 1.00 (7/7) | 1.00 (7/7) | 0.29 → 0.29 | 0/11 → 0/11 |
| Spelling | fr | 1.00 (3/3) | 1.00 (3/3) | 0.13 → 0.13 | 0/11 → 0/11 |

## Held-out results

Graded once on 2026-11-02 on macOS 27.2, after the tuning was committed. No language detection
missed and no request failed.

| Mode | Language | Precision | Recall | Clean flagged | p50 / p90 | Verdict |
|---|---|---|---|---|---|---|
| Model | en | 1.00 (17/17) | 1.00 (17/17) | 0/7 | 459 / 510 ms | pass |
| Model | nl | 0.91 (10/11) | 0.71 (10/14) | 0/7 | 428 / 501 ms | fail: precision, recall |
| Model | fr | 0.87 (13/15) | 0.81 (13/16) | 0/7 | 396 / 464 ms | fail: precision, recall |
| Spelling | en | 0.67 (6/9) | 0.35 (6/17) | 1/7 | 2 / 19 ms | fail: precision |
| Spelling | nl | 1.00 (7/7) | 0.50 (7/14) | 0/7 | 2 / 17 ms | pass |
| Spelling | fr | 0.67 (2/3) | 0.12 (2/16) | 1/7 | 2 / 29 ms | fail: precision |

### Default changes

Provisional until Michael reviews the data:

- **Dutch:** model checks are off by default (model precision 0.91). Spelling only passes, so
  checking while typing stays on, as spelling only.
- **French:** model checks and checking while typing are off by default (model precision 0.87,
  spelling-only precision 0.67). The panel still works in French.
- **English:** no change. Its spelling-only miss has no effect while the model path passes.
- The recall misses (Dutch 0.71, French 0.81) change no default; they go in the merge request.

### What missed

A diagnostic run with the guard off, made after the grade, separates the model's misses from the
guard's. Nothing was tuned after the held-out run.

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
