# Releasing Through a Pull Request (Skald Port) Implementation Plan

**Status:** Implemented ([pull request #3](https://github.com/michaelrigart/skald/pull/3)). Completed: do not run this plan again. Codex approved it in round 1 (`xr-1794862861-42887a52`).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Skald's `scripts/release` lands its release commit through a pull request it opens, checks and merges, exactly as Muninn's does, with its test and documentation to match.

**Architecture:** A port, not a reimplementation. `scripts/release` and `scripts/tests/test-release-dry-run` are Muninn's files at commit `M`, passed through the rename below; the test then drops Muninn's zap cases and names Skald's changelog entry. The documentation follows Muninn's at `M`, in Skald's words.

**Tech Stack:** bash, `gh`, git, `xcodebuild` through `scripts/release`, Python 3 (`scripts/changelog.py`, unchanged).

**Spec:** `docs/superpowers/specs/2026-11-16-release-via-pull-request-design.md` (Skald's differences). It names the canonical design, Muninn's `docs/superpowers/specs/2026-11-16-release-via-pull-request-design.md`, which holds the behaviour. Read both.

**Source (`M`):** `ee810a9aa04404599715aac48158e2a2d20f5059` on Muninn's `fix/release-via-pr` ("Say which stopped releases the README's resume covers"), approved by Codex's pre-merge review (`xr-1794908533-fc04b075`, Muninn PR #8). Muninn's release suite passes 475 of 475 at `M`, so Skald's expects 471 of 471. The first port took `092d5f8d2d083a789b2f5545543febbd68b14878` (`xr-1794905228-ba53f276`); "Re-port" below took this one. Every command below reads two shell variables the implementer sets first: `M`, that full SHA, and `MUNINN`, the path of a Muninn checkout that has it (the driver gives both in each brief). `git -C "$MUNINN" cat-file -e "$M^{commit}"` must succeed before any step runs.

**Base:** `feat/skald-v1` at `c88dfad`; the pull request targets `feat/skald-v1`, not `main` (spec, "Base branch").

## Global Constraints

- **Rename:** `sed -e 's/muninn/skald/g' -e 's/Muninn/Skald/g'`. Team `CX4MWR5579` and tap `michaelrigart/homebrew-tap` are the same in both repositories and need no change. Measured on Muninn's `main` (`56c3e8b`): this rename of its `scripts/release` equals Skald's today.
- **Allowed differences** in `scripts/tests/test-release-dry-run` after the rename, and no others: no `zap_is_settings_only` helper and none of its four cases (Skald adds no zap check of its own); the "section holds only the fixture's text" case names Skald's entry `Skald v1: check spelling`. `scripts/release` has none.
- **Muninn is read-only:** read `M` with `git -C "$MUNINN" show "${M}:<path>"`; never edit, commit, check out or fetch in `$MUNINN`.
- **Port through a file:** `git show` writes to `$TMPDIR` first and `sed` runs only if it succeeded, so a failed read never empties a Skald file.
- **Commands:** the suite and `scripts/release --dry-run` need the keychain signing identity and Xcode. Run them outside the agent sandbox, prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, under Michael's normal git configuration: no `GIT_CONFIG_GLOBAL` override (spec, "Test runs"). Never run `scripts/release` without `--dry-run`.
- **Sandbox:** process substitution (`<(...)`) and `diff -` on a pipe fail inside the sandbox; diff through files in `$TMPDIR`.
- **No `CHANGELOG.md` entry:** nothing changes for users.
- **Touch only the named lines** of `README.md` and `AGENTS.md`: `feat/skald-v1` may edit them meanwhile.
- **Commits:** implementers do not commit; the controller commits each task on its own, imperative mood, no agent attribution.
- **Public repository:** no machine-specific paths in any committed file.

## Review Focus

1. **Muninn-only content the rename makes look like Skald's** (`~/.config/skald`, "Skald records calls", FluidAudio, meetings, models, transcripts). Skald's cask zaps its own paths and its changelog has none of these. Expected: none left once the allowed differences are made. (Task 1, Step 2.)
2. **A rename inside a link to Muninn** (a comment citing Muninn's design by URL or path) becomes a link to a Skald file that does not exist. Expected: every `michaelrigart/skald` URL and every `docs/` path in the ported files exists in Skald, or the line keeps Muninn's name. (Task 1, Step 2.)
3. **Muninn's branch moves after `M`, before the merges:** Skald takes the change too (spec, "What Skald takes"). Expected: the port is redone from the new commit, never patched by hand. ("Re-port" below.)
4. **The dry run on this checkout with a token that cannot merge** (an agent session's `gh` token): it notes that and exits 0, creating no branch, tag, pull request or release anywhere. (Task 1, Step 8.)
5. **Documentation that still says the script pushes `main`** (AGENTS.md's "it … pushes" today). Expected: no such claim left. (Task 2, Step 4.)

---

### Task 1: Port the release script and its test

**Depends on:** none (needs `M`).

**Files:**
- Modify: `scripts/release`
- Modify: `scripts/tests/test-release-dry-run`

**Interfaces:**
- Consumes: `"${M}:scripts/release"` and `"${M}:scripts/tests/test-release-dry-run"` in `$MUNINN`.
- Produces: the release flow Task 2 documents. Nothing calls it from code.

- [ ] **Step 1: Port the test**

```bash
git -C "$MUNINN" show "${M}:scripts/tests/test-release-dry-run" >"$TMPDIR/muninn-test" \
  && sed -e 's/muninn/skald/g' -e 's/Muninn/Skald/g' "$TMPDIR/muninn-test" >scripts/tests/test-release-dry-run
```

Then make the allowed differences, and only those:
- delete `zap_is_settings_only` with its comment, and the four cases that call it with their fixture files (`a: the cask zaps only the settings`, `a: an extra zap target fails`, `a: a zap list fails`, `a: a delete elsewhere fails`). Keep `rejects`: the `.noindex` cases use it. Put nothing in their place;
- in `a: the section holds only the fixture's text`, replace the renamed Muninn entry with `"Skald v1: check spelling"`.

If Muninn's test at `M` no longer has these as described, stop and report to the controller.

- [ ] **Step 2: Check for content the rename got wrong**

Run: `rg -n -i 'muninn|record|meeting|FluidAudio|model|transcri|zap|\.config|Application Support|michaelrigart/skald/(blob|tree)|docs/' scripts/tests/test-release-dry-run`
Expected: no hit, or only a `docs/` path or Skald URL that exists in this repository. Report any other hit to the controller; it is a spec question, not an edit.

- [ ] **Step 3: Run the ported test against today's script (the revert check)**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/tests/test-release-dry-run`
Expected: exits non-zero, with `FAIL` lines for the pull-request cases (among them the new release landing through a pull request and the token refusals).

- [ ] **Step 4: Port the script**

```bash
git -C "$MUNINN" show "${M}:scripts/release" >"$TMPDIR/muninn-release" \
  && sed -e 's/muninn/skald/g' -e 's/Muninn/Skald/g' "$TMPDIR/muninn-release" >scripts/release
```

Run Step 2's `rg` on `scripts/release`. Expected: no hit. Both files keep mode 755 (`git diff --summary` shows no mode change).

- [ ] **Step 5: Diff against Muninn (spec, Acceptance 1)**

```bash
for f in scripts/release scripts/tests/test-release-dry-run; do
  git -C "$MUNINN" show "${M}:$f" >"$TMPDIR/source" || { echo "cannot read ${M}:$f"; break; }
  sed -e 's/muninn/skald/g' -e 's/Muninn/Skald/g' "$TMPDIR/source" >"$TMPDIR/ported"
  echo "== $f"; diff "$TMPDIR/ported" "$f"
done
```

Expected: nothing for `scripts/release`; for the test, only the hunks of Step 1.

- [ ] **Step 6: Run the suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/tests/test-release-dry-run`
Expected: exit 0, last line `N of N cases passed` with N = Muninn's total at `M` minus four (its zap cases).

- [ ] **Step 7: Commit** (controller)

```bash
git add scripts/release scripts/tests/test-release-dry-run
git commit -m "Release through a pull request, as Muninn does"
```

- [ ] **Step 8: Dry run on this checkout (spec, Acceptance 3)**

Before: record `git ls-remote origin 'refs/heads/release/*' 'refs/tags/*'` and `gh pr list --repo michaelrigart/skald --state all --limit 5 --json number`.
Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/release --dry-run`
Expected: exit 0; last line `Dry run: nothing committed, branched, pushed, merged, tagged or published.`; a note if the session's `gh` token cannot merge. After: `git status --short` empty, `git branch --list 'release/*'` empty, HEAD still on `fix/release-via-pr`, and both recorded listings unchanged.

### Task 2: Document releasing through a pull request

**Depends on:** Task 1 (documents its behaviour).

**Files:**
- Modify: `README.md` ("Releasing")
- Modify: `AGENTS.md` (the "Release" line under "Commands"; a new "Release flow" line under "Releases and CI")
- Modify: `docs/superpowers/specs/2026-11-05-skald-distribution-design.md` (one line under the header)

**Interfaces:**
- Consumes: Muninn's `README.md`, `AGENTS.md` and `docs/superpowers/specs/2026-11-03-muninn-distribution-design.md` at `M`.

- [ ] **Step 1: README, "Releasing"**

Take the release paragraph of Muninn's "Releasing" at `M`, renamed; keep Skald's sentence on `design/render` as it is. It must say (spec, Documentation): the release commit goes through a pull request the script opens and merges as admin; `gh` must use a login with the `repo` scope of an admin account; a failed run says where it stopped, and `--version` resumes it.

- [ ] **Step 2: AGENTS.md**

- The "Release" line: Muninn's at `M`, renamed, with Skald's "Michael" where Muninn says "the maintainer". It says the script pushes a release branch and merges its pull request, never `main`.
- Under "Releases and CI", after the unchanged "Distribution design" line, add Muninn's "Release flow" line, naming the canonical design too (spec, Documentation), wrapped at 100 columns:
  ``- Release flow: `docs/superpowers/specs/2026-11-16-release-via-pull-request-design.md`, which ports Muninn's design (https://github.com/michaelrigart/muninn/blob/main/docs/superpowers/specs/2026-11-16-release-via-pull-request-design.md).``

- [ ] **Step 3: Distribution design**

Add Muninn's `**Release flow:**` header line at `M` as the last header line, after **Template:**, unchanged (its path is Skald's port spec). Change nothing else in the file.

- [ ] **Step 4: Check**

Run: `rg -n -i 'push' README.md AGENTS.md`
Expected: no line says `scripts/release` pushes `main` or pushes without naming the release branch.
Run: `git diff --stat`
Expected: exactly the three files.

- [ ] **Step 5: Commit** (controller)

```bash
git add README.md AGENTS.md docs/superpowers/specs/2026-11-05-skald-distribution-design.md
git commit -m "Document releasing through a pull request"
```

## Final verification (controller, on the last commit)

Outside the sandbox, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:

- `swift test --package-path Packages/SkaldCore` and `swift test --package-path Packages/SkaldPlatform27`: pass.
- `/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'` and `scripts/tests/test-release-dry-run`: pass.
- `mise exec -- xcodegen generate`, then a Release and a Debug build into `build/dd.noindex`, then `scripts/tests/test-verify-app build/dd.noindex/Build/Products/Release/Skald.app build/dd.noindex/Build/Products/Debug/Skald.app`: pass.

Report totals as passed/total.

## Re-port

If Muninn's `fix/release-via-pr` gains commits after `M` before the merges and its pre-merge review passes again: set `M` to the new commit here, redo Task 1 Steps 1–2 and 4–6 and Task 2 Steps 1–4 from it, and commit "Take Muninn's <subject> into the release flow". Never edit the ported files by hand to follow Muninn.

## Finishing (controller)

- Before pushing, check that `feat/skald-v1` has not changed `scripts/release` or `scripts/tests/test-release-dry-run` since `c88dfad`; if it has, stop and tell Michael.
- Push `fix/release-via-pr` and open a draft pull request into `feat/skald-v1` (`merge-request` skill). Its body says it merges only after Muninn's pull request, that every pull request of the change (canonical design, "Ports") is opened before any merges, and that the Skald session on `feat/skald-v1` is told when it merges. CI passes on it (spec, Acceptance 4) before the work is reported done.
- Set the port spec's **Status** to `In progress` with the pull request; in the final pre-merge commit, `Implemented` citing it, and mark this plan completed.
- Spec Acceptance 5 (Skald's first real release lands, tags and publishes in one run) is Michael's, after v1 merges into `main`.
