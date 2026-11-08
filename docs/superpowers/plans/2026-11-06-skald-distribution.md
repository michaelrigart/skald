# Skald Distribution Implementation Plan

**Status:** In progress (branch `feat/skald-distribution`, branched from `feat/skald-v1` at
`08d308b`; no merge request yet, because the repository has no remote). Tasks 1–9 are done at
`aa1eadf` (2026-11-06): do not run them again. Tasks 10 and 11 remain, with Michael.

**Execution notes:** one task at a time, in this order: 1, 5, 2, 3, 4, 8, 6, 7, 9 (most tasks
build into `build/`, and Tasks 1 and 8 both edit `project.yml`); Tasks 10 and 11 with Michael.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Skald the way Hulder ships: versioned `YYYYMMDD-HHMM`, verified, released in one
command, installed with Homebrew, with CI on `xcode-27`, the designer's artwork, and no probe in
any release.

**Architecture:**
- Port Hulder's tooling (`scripts/release`, `scripts/verify-app`, `scripts/changelog.py`,
  `scripts/tests/*`, `scripts/hulder.rb.template`, `.github/workflows/ci.yml` in the
  `michaelrigart/hulder` repository) with Skald's names and the differences the spec lists.
- Port Muninn's `design/render` (it also renders the menu bar glyph) from `michaelrigart/muninn`.
- Two small app changes: the probe compiles only in Debug, and Skald refuses to check when it
  isn't run from `/Applications`, and says so.
- Signing already moved to the Personal Team on `feat/skald-v1` (commit "Sign builds with the
  Apple Development certificate").

**Tech Stack:** bash, Python 3 (`/usr/bin/python3`, standard library only), GitHub Actions,
XcodeGen through mise, Xcode 27, Swift 6, Swift Testing, `rsvg-convert`.

**Spec:** `docs/superpowers/specs/2026-11-05-skald-distribution-design.md`. Read it, then Hulder's
spec it names and Hulder's scripts.

## Global Constraints

- **Repository:** this repository, branch `feat/skald-distribution`. Commit each task on its own,
  imperative mood, no agent attribution or co-author lines. Never push to `main`; never create a
  tag, release or cask (Task 11 is Michael's).
- **Commands:** `swift test`, `xcodebuild`, `xcodegen`, `codesign` and `security` run outside the
  agent sandbox, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- **Team ID:** `CX4MWR5579`. It is public. Pick the identity by Team ID, never by the bare name.
- **Versions:** `MARKETING_VERSION` is `dev` and `CURRENT_PROJECT_VERSION` is `0` outside a
  release. A release is `YYYYMMDD-HHMM`, with build number `YYYYMMDDHHMM`.
- **Product:** bundle identifier `com.michaelrigart.skald`, `LSUIElement` true, no entitlements,
  Hardened Runtime on, Apple silicon only (`ARCHS=arm64`), `LSMinimumSystemVersion` 27.0.
- **Releases:** asset `Skald-<version>.zip`, cask `Casks/skald.rb` in `michaelrigart/homebrew-tap`,
  `app "Skald.app", target: "/Applications/Skald.app"`.
- **Probe:** the feasibility probe (`--probe`, `Packages/SkaldPlatform27/Sources/SkaldPlatform27/Probe/`)
  compiles only under `#if DEBUG`; its marker string is `~skald-probe~`.
- **Public repository:** no machine-specific paths, no certificate, key or token; `Eval/` data is
  synthetic with no real company names.
- **Code:** `SkaldCore` imports only Foundation and Observation; UTF-16 offsets.

## Review Focus

1. **A Release bundle that still carries the probe** (a `#if DEBUG` missed in one file) →
   `verify-app` fails on the marker string. (Task 3's Debug-copy case and Task 2's Release build.)
2. **A dirty tree, the wrong branch, or `main` behind `origin/main`** → `scripts/release` stops
   before building and names the check. (Task 6's dry-run tests.)
3. **A resumed release whose tag points elsewhere, or whose local commit isn't exactly
   `Release <version>` changing only `CHANGELOG.md`** → the script stops and names the commit.
   (Task 6.)
4. **Skald launched from `~/Downloads`, `~/Applications` or a build folder** → no checking, and it
   says to move it. (Task 4.)
5. **A CI runner without Accessibility, Apple Intelligence or spare CPU** → both suites pass; a
   test that depends on the machine is fixed, not skipped. (Task 7.)

---

### Task 1: Version builds

**Depends on:** none

**Files:**
- Modify: `project.yml`

- [x] **Step 1:** In `settings.base` add `MARKETING_VERSION: dev`, `CURRENT_PROJECT_VERSION: "0"`;
  in `info.properties` set `CFBundleShortVersionString: $(MARKETING_VERSION)`,
  `CFBundleVersion: $(CURRENT_PROJECT_VERSION)` and `LSMinimumSystemVersion: "27.0"` (if
  XcodeGen doesn't already set it from the deployment target). Generate the project; build Debug
  and Release.
- [x] **Step 2: Check** with `codesign -dvvv` on the Release product: `TeamIdentifier=CX4MWR5579`,
  an `Apple Development` authority, `flags=…(runtime)`; `codesign -d -r-` shows a designated
  requirement naming the certificate and team, not a `cdhash`; `codesign -d --entitlements -`
  shows none or an empty dictionary (no `get-task-allow`); `lipo -archs` prints `arm64`;
  `PlistBuddy` shows `dev` and `0`. Then the ad-hoc override (`CODE_SIGN_IDENTITY=-
  DEVELOPMENT_TEAM=`) builds Release ad hoc.
- [x] **Step 3: Commit** "Version builds".

### Task 2: Keep the probe out of Release

**Depends on:** Task 1

**Files:**
- Modify: every file in `Packages/SkaldPlatform27/Sources/SkaldPlatform27/Probe/`, the probe-only
  helpers it alone uses (for example `Access/TextMarkerField.swift`, if nothing outside the probe
  uses it), `Skald/SkaldApp.swift`, and the probe's tests

- [x] **Step 1:** Wrap each probe source file's contents in `#if DEBUG … #endif`, and the app's
  `--probe` argument handling in `SkaldApp.swift` likewise. Probe tests get the same guard, so
  `swift test` (Debug) still runs them. Anything the shipping app needs (for example
  `AppAccessibilityMode`, `AXQueue`, `AXElement`) stays unguarded.
- [x] **Step 2: Build Release.** `grep -aF '~skald-probe~'` and `grep -aF -- '--probe'` on the
  Release executable find nothing; on the Debug executable both are found. Both suites pass.
- [x] **Step 3: Commit** "Compile the probe only in Debug builds".

### Task 3: Verify a built app

**Depends on:** Task 2

**Files:**
- Create: `scripts/verify-app`, `scripts/tests/test-verify-app` (both executable)

**Interfaces:**
- Produces: `scripts/verify-app [--team <ID>] <Skald.app> [<version>]` — exit 0 when every check
  passes, otherwise each `FAIL: <reason>` and exit 1. Tasks 6 and 7 call it.

- [x] **Step 1: Port Hulder's `verify-app`** with Skald's bundle identifier, and the spec's checks:
  signature, Hardened Runtime flag, architectures exactly `arm64`, `LSMinimumSystemVersion` ≥ 27.0,
  empty entitlements, `LSUIElement` true, the probe strings (`~skald-probe~`, `--probe`; the log
  category word `probe` doesn't count), versions, and `--team`.
- [x] **Step 2: Port `test-verify-app`.** Each tampered copy fails with its reason: a changed bundle
  identifier; `LSUIElement` false; a wrong version; an added `get-task-allow` (re-signed ad hoc);
  re-signed without `--options=runtime`; a universal executable (`lipo -create` with an `x86_64`
  slice from any system binary); `LSMinimumSystemVersion` 26.0; the Debug build (the probe).
- [x] **Step 3: Run** `scripts/verify-app --team CX4MWR5579 build/Build/Products/Release/Skald.app`
  (passes) and `scripts/tests/test-verify-app <Release Skald.app> <Debug Skald.app>` (every
  tamper case fails as expected).
- [x] **Step 4: Commit** "Verify built apps".

### Task 4: Refuse to check outside /Applications

**Depends on:** Task 3 (builds share `build/`). If v1's app shell already has this check, this
task only adds the tests that are missing and says so.

**Files:**
- Create: `Packages/SkaldCore/Sources/SkaldCore/InstallLocation.swift`,
  `Packages/SkaldCore/Tests/SkaldCoreTests/InstallLocationTests.swift`
- Modify: the app shell's composition (where v1 starts the pipeline and the status item)

**Interfaces:**
- Produces: `public enum InstallLocation { public static func isSupported(bundlePath: String) -> Bool }`
  — true only when the bundle's standardized parent directory is exactly `/Applications`.

- [x] **Step 1: Failing tests:** `/Applications/Skald.app` → true;
  `/Applications/../Applications/Skald.app` → true; `/Applications/Utilities/Skald.app`,
  `/Users/x/Applications/Skald.app`, `/Users/x/Downloads/Skald.app` and
  `/Users/x/Code/skald/build/Build/Products/Release/Skald.app` → false.
- [x] **Step 2: Run; they fail.** **Step 3: Implement,** and in the app: when
  `InstallLocation.isSupported(bundlePath: Bundle.main.bundlePath)` is false, start no pipeline
  and no text access, and show "Move Skald to the Applications folder, then open it again." (in
  the status menu, and once as an alert at launch). **Step 4:** both suites pass; build Debug.
- [x] **Step 5: Commit** "Refuse to check when Skald isn't in /Applications".

### Task 5: Changelog and its tool

**Depends on:** none

**Files:**
- Create: `CHANGELOG.md`, `scripts/changelog.py`, `scripts/tests/test_changelog.py`

- [x] **Step 1: Port Hulder's `changelog.py` and its tests unchanged,** apart from the repository
  URL `https://github.com/michaelrigart/skald`.
- [x] **Step 2: Write `CHANGELOG.md`** in Hulder's format and preamble. `## [Unreleased]` holds,
  under `### Added`: Skald v1 (spelling and grammar checking on device in English, Dutch and
  French, underlines or a badge and cards, the panel, the optional remote engines — worded from
  what v1 shipped), the Homebrew cask, signed releases that keep the Accessibility grant, and the
  move notice outside `/Applications`; plus the `[Unreleased]` link definition.
- [x] **Step 3: Run** `/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'`. Passes.
- [x] **Step 4: Commit** "Add the changelog and its tool".

### Task 6: Release script and cask template

**Depends on:** Tasks 1, 3, 5

**Files:**
- Create: `scripts/release`, `scripts/skald.rb.template`, `scripts/tests/test-release-dry-run`

- [x] **Step 1: Port Hulder's `scripts/release` and `test-release-dry-run`** with Skald's names,
  project, scheme, asset name, cask file and `verify-app --team`. Keep Hulder's recovery rules for
  an unpushed release commit unchanged.
- [x] **Step 2: Write `skald.rb.template`** from Hulder's: `name "Skald"`, `desc "Spelling and
  grammar checker for the menu bar"`, the repository as `homepage`, `livecheck`, `depends_on arch:
  :arm64` and Hulder's macOS 27 symbol, `app "Skald.app", target: "/Applications/Skald.app"`,
  `uninstall quit: "com.michaelrigart.skald"`, `zap trash:` the paths v1 writes (at least
  `~/Library/Application Support/com.michaelrigart.skald`; check the app for others), and
  `caveats`: "Open Anyway" on first launch, allowing Skald under Accessibility, Apple Intelligence
  on for model checks, and that `zap` keeps the Keychain item with the Claude API key (README says
  how to delete it).
- [x] **Step 3: Commit** "Add the release script and the cask template" (the script refuses a
  dirty tree, even for a dry run).
- [x] **Step 4: Run** `scripts/tests/test-release-dry-run`, then `scripts/release --dry-run` on
  this branch: it builds team-signed, passes `verify-app` with the version, writes
  `Skald-<version>.zip` and prints the changelog section. Delete the zip. A failure is fixed in a
  follow-up commit and Step 4 runs again.

### Task 7: CI

**Depends on:** Tasks 3, 5

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `mise.toml` (add `actionlint` at Hulder's pin); any test that depends on the machine
- Test: `Packages/SkaldPlatform27/Tests/SkaldPlatform27Tests/ProcessCPUTests.swift`

- [x] **Step 1: Port Hulder's `ci.yml`** (`runs-on: xcode-27`, the same explicit Xcode selection,
  the same pinned action SHAs if they still exist): changelog tests, both `swift test` suites,
  `xcodegen generate`, Release and Debug builds with `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`,
  `verify-app` on Release, `test-verify-app` on both. `mise exec -- actionlint` passes.
- [x] **Step 2: Harden machine-dependent tests.** `busyChildReadsAsAboutOneCore` failed once on
  2026-11-05 while the Mac was busy: assert a lower bound that a loaded runner meets (the busy
  child gets measurably more than 0 % and at most about one core), and run it 20 times under load
  (while a Release build runs) without a failure. Tests needing Foundation Models stay gated on
  `SystemLanguageModel.default.isAvailable`; check every test touching the spell server, the
  Keychain or Accessibility passes without them, or fix it so it does.
- [x] **Step 3: Run locally** what CI will run, with the ad-hoc override. All pass.
- [x] **Step 4: Commit** "Run CI on the Xcode 27 image". CI itself runs once the pull request
  exists (Task 10); the controller watches that run and fixes failures in new commits.

### Task 8: Artwork

**Depends on:** none

**Files:**
- Create: `design/app-icon.svg`, `design/mark.svg`, `design/mark-on-light.svg` (the designer's
  files; the controller gives their folder in the dispatch), `design/menubar.svg` (the version
  Michael approved; the controller gives its path), `design/render` (executable),
  `Skald/Assets.xcassets/Contents.json`, `Skald/Assets.xcassets/AppIcon.appiconset/*`,
  `Skald/Assets.xcassets/SkaldMenuBar.imageset/*`
- Modify: `project.yml` (`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`), the status item (v1's
  app shell) to use `NSImage(named: "SkaldMenuBar")` as a template image, `.gitignore` if needed

- [x] **Step 1: Port Muninn's `design/render`:** it renders `design/app-icon.svg` into every PNG
  listed in `AppIcon.appiconset/Contents.json` at its pixel size, and `design/menubar.svg` into
  `SkaldMenuBar@1x.png` (18 px) and `@2x.png` (36 px), with `rsvg-convert`; it checks
  `rsvg-convert` is installed and says to install Homebrew `librsvg` if not.
- [x] **Step 2:** Copy the four SVGs into `design/`. Write the asset catalog: `AppIcon.appiconset`
  with Hulder's `Contents.json` (filenames `icon_<size>x<size>[@2x].png`), and
  `SkaldMenuBar.imageset` with Hulder's `Contents.json` shape (`template-rendering-intent:
  template`). Run `design/render`, and check each PNG's pixel size against its slot
  (`sips -g pixelWidth`). The delivered PNGs and `.icns` are not committed.
- [x] **Step 3:** Point the status item at `SkaldMenuBar` (template), set the app icon name, build
  Debug. Finder shows the icon for the built app (`mdls -name kMDItemDisplayName` is not enough:
  check `Contents/Resources/Assets.car` exists and `CFBundleIconName` is `AppIcon`).
- [x] **Step 4: Commit** "Add the app icon and the menu bar glyph".

### Task 9: README and AGENTS.md

**Depends on:** Tasks 1–8

**Files:**
- Create: `README.md`
- Modify: `AGENTS.md`

- [x] **Step 1: Write `README.md`:** what Skald does; that it needs macOS 27 on Apple silicon,
  must run from `/Applications`, and needs Apple Intelligence for model checks; the Homebrew
  install with its first-run steps (the cask's caveats); building from source with the ad-hoc
  override, and the probe (Debug only); what each app supports, from the feasibility check's
  finding 7 in the v1 spec; how to delete the Keychain item with the Claude API key (`security
  delete-generic-password -s com.michaelrigart.skald -a claude-api-key`); a pointer to the specs.
  No machine details.
- [x] **Step 2: Update `AGENTS.md`:** the release command, `verify-app`, `design/render`; CI on
  `xcode-27`, signed ad hoc; user-visible changes add a `CHANGELOG.md` entry under `Unreleased`.
- [x] **Step 3: Commit** "Document installing, building and releasing".

### Task 10: Publish the repository (with Michael)

**Depends on:** Tasks 1–9, and v1's pull request being ready.

- [ ] **Step 1: Audit the whole history** of every branch to be pushed: `gitleaks git` finds
  nothing; no machine details in tracked docs (hardware models, local paths beyond the
  repository's own); no real company names or customer text in `Eval/` or the fixtures; nothing
  under `.superpowers/` tracked. Report findings to Michael before any push.
- [ ] **Step 2:** With Michael's go for this step: `gh repo create michaelrigart/skald --public`,
  add it as `origin`, push `main`, then `feat/skald-v1` and `feat/skald-distribution`. Open v1's
  draft pull request against `main`, then this one (its description notes it is stacked on v1).
- [ ] **Step 3:** Watch CI on both; fix failures in new commits.
- [ ] **Step 4, after v1's pull request merges:** rebase `feat/skald-distribution` onto `main`
  (dropping v1's commits if v1 was squash-merged), force-push it with a lease, check the pull
  request now shows only this plan's commits, let CI pass again, and run the pre-merge review on
  the rebased branch before it merges.

### Task 11: Acceptance with Michael

**Depends on:** Task 10. Needs Michael at the Mac.

- [x] **Step 1: Grant retention, on this branch's final builds.** With the grant Skald already
  holds (no new grant): quit Skald and confirm it has exited (`pgrep -x Skald` prints nothing),
  reinstall a team-signed Debug rebuild of this branch's head in `/Applications` (`rm -rf` then
  `ditto`), launch it with `open`, and check that the new process (a new PID, and a "Skald
  started" log line after the reinstall) is trusted (`AXIsProcessTrusted`, as the app logs at
  launch, or its permission status in the status menu). Then the same, quitting and confirming
  the exit again, for the Release product of `scripts/release --dry-run`. Record both
  results, and the one grant at the switch from ad hoc (from v1's probe runs), under Signing in
  the spec as "Measured on <date>".
- [x] **Step 2:** Update every place that states the grant behaviour — README, AGENTS.md,
  `CHANGELOG.md`, the cask caveats — from Step 1's results only, dropping the "should survive"
  hedge only where Step 1 measured it.
- [x] **Step 3:** Quit the installed copy and confirm it has exited (`pgrep -x Skald` prints
  nothing), then run the Release product from outside `/Applications`: the move notice shows,
  nothing is checked. Quit it and delete that copy afterwards.
- [x] **Step 4:** The menu bar glyph in a light and a dark menu bar, and the icon in Finder and the
  Dock.
- [ ] **Step 5, after both pull requests merge:** Michael runs `scripts/release`; then
  `brew install --cask michaelrigart/tap/skald` and "Open Anyway". Record whether macOS asked
  for Accessibility again (the release is team-signed like the builds in Step 1, so it should
  not); grant it only if asked. Skald checks text and Settings shows the version (spec
  acceptance 7). Acceptance 8 is checked at the second release.
