# Skald distribution — design

**Date:** 2026-11-05
**Owner:** Michael Rigart
**Status:** In progress (branch `feat/skald-distribution`; no pull request yet, because the
repository has no remote). Signed off by Michael on 2026-11-06 after Codex's spec review (round 2,
`xr-1793919517-ca7c3e9d`). The work runs on `feat/skald-distribution` after v1's tasks.
**Template:** Hulder's distribution design (`michaelrigart/hulder`,
`docs/superpowers/specs/2026-11-03-hulder-distribution-design.md`), which follows Linger's, and
Muninn's for the menu bar glyph. Michael asked for the same here (2026-11-05). This document
repeats what applies to Skald, so it can be planned on its own, and states where Skald differs.

## Why

Skald runs only as a local build, installed by hand. Until 2026-11-05 its ad-hoc signature
changed with every build, so every probe build needed the Accessibility grant again. There is no
way to install or upgrade Skald except by building it from source, and no artwork: the menu bar
shows a system symbol and the app has no icon.

Michael wants what Hulder, Muninn and Linger have:
- Skald installable with Homebrew;
- releases he can cut in one step;
- CI on every change;
- a signing identity that keeps the Accessibility grant across rebuilds;
- the designer's icon and mark in the app.

## Goals

- `brew install --cask michaelrigart/tap/skald` installs Skald, and `brew upgrade` upgrades it.
- One command on Michael's Mac cuts a release: it sets the version, updates the changelog,
  builds, signs, verifies, packages, tags, publishes the GitHub release and updates the cask.
- The Accessibility grant survives rebuilds and upgrades.
- CI tests and builds every pull request and every push to `main`.
- The app icon and the menu bar glyph can be regenerated from SVG sources in the repository.

## Non-goals

As for Hulder: no Developer ID signing or notarization (Michael declined the paid program for
Linger), no Mac App Store, no in-app updates (Homebrew upgrades), no signing in CI, Apple silicon
only, macOS 27 only.

## Anti-goals

- The cask must not strip the quarantine attribute or otherwise bypass Gatekeeper.
- No certificate, private key, token or API key in the repository or in CI.
- The release script pushes to `main` only its own release commit (the changelog section),
  plus the tag. Only Michael runs it.
- No machine-specific paths or settings in the repository. It is public.
- No release may contain the Debug-only feasibility probe.

## Decisions (Michael's)

- **Same as Hulder** (2026-11-05): versions, signing, Homebrew tap, changelog format, CI on
  GitHub's `xcode-27` image, design sources in the repository, Apple silicon only.
- **Sign now** (2026-11-05): the switch to the Personal Team certificate lands on `feat/skald-v1`
  as a small change before the next probe build, not with the rest of this work.
- **A public repository** `michaelrigart/skald` (2026-11-05), created when this work needs it;
  the cask goes to the existing `michaelrigart/homebrew-tap`.
- **Timing** (2026-11-05): this design and its plan now; the work runs after v1's remaining
  tasks, and the first real release follows v1's merge.

## How it works

### Versions

As Hulder: the version is `date +%Y%m%d-%H%M` when the release script starts, with no `v`
prefix; it is the tag, the release title, part of `Skald-<version>.zip` and the cask's
`version`. `MARKETING_VERSION=<version>` becomes `CFBundleShortVersionString` and
`CURRENT_PROJECT_VERSION=<digits>` becomes `CFBundleVersion`. `project.yml` today hard-codes
`"0.1.0"` and `"1"`; they become `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`, with
`dev` and `0` for builds outside the release script. Settings › About shows the version once
v1's Settings window exists.

### Signing

- Manual signing with the identity `Apple Development` and `DEVELOPMENT_TEAM: CX4MWR5579`
  (Michael's Personal Team, as for Hulder and Linger), for Debug and Release, Hardened Runtime on,
  `ARCHS: arm64`, and `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` for Release so it has no
  `get-task-allow`. This part is done on `feat/skald-v1` (see Decisions); the result of the first
  rebuild with the grant is recorded here when measured.
- Skald has no entitlements: it is not sandboxed, reaches the network for the optional remote
  engines without one, and keeps the Claude API key as a generic Keychain item.
- Anyone without the certificate (CI, contributors) builds ad hoc with
  `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`; their grant resets on every rebuild.
- Scripts pick the signing identity by Team ID, never by the bare name.

### The probe stays out of releases

The feasibility probe (`--probe`, `SkaldPlatform27/Probe/`) writes into other apps and swaps
the clipboard, so it must never ship. Its sources and the app's `--probe` handling compile only
under `#if DEBUG`, as Hulder's probe does. `skald-eval` is a separate SwiftPM executable and is
never bundled.

### Verifying a built app

`scripts/verify-app [--team <ID>] <Skald.app> [<version>]`, from Hulder's, fails unless:
- `codesign --verify --strict` passes;
- the signature carries the Hardened Runtime flag (`runtime` in `codesign -dv`'s flags);
- the executable's architectures are exactly `arm64` (`lipo -archs`);
- `LSMinimumSystemVersion` is 27.0 or later;
- the entitlements are empty;
- `LSUIElement` is true and the bundle identifier is `com.michaelrigart.skald`;
- the executable contains neither the probe marker `~skald-probe~` nor the `--probe` flag
  string (the log category named `probe` doesn't count);
- with a version, both version keys match; with `--team`, the `TeamIdentifier` matches.

`scripts/tests/test-verify-app` checks that it rejects a tampered copy, a Debug build, a copy
re-signed without Hardened Runtime, a universal (`arm64` + `x86_64`) executable and a lower
minimum system version.

### CI

`.github/workflows/ci.yml`, as Hulder's: pull requests and pushes to `main`, `runs-on: xcode-27`
with an Xcode 27 release selected explicitly, `permissions: contents: read`, a cancelling
concurrency group, every action pinned to a full SHA, XcodeGen and `actionlint` from
`mise.toml`. Steps: the changelog tool's tests; `swift test` for `SkaldCore` and
`SkaldPlatform27`; `xcodegen generate`; Release and Debug builds signed ad hoc; `verify-app` on
Release; the verifier's own test.

The runner has no Accessibility grant and no Apple Intelligence. Tests that need Foundation
Models are already gated on `SystemLanguageModel.default.isAvailable`; any other test that
depends on the machine (the system spell server, CPU timing under load) is a defect to fix so it
passes there, not a test to skip. The CPU sampling test that failed once under load on
2026-11-05 is one to harden. The one exception is the guard against real company names in
`Eval/` and in file names: it reads a private list that never enters the repository or CI, so
it runs on Michael's Mac and in the audit before every push, and skips in CI (Michael's
decision, 2026-11-06).

### Changelog

`CHANGELOG.md` in Hulder's format (Keep a Changelog, the `YYYYMMDD-HHMM` preamble,
`## [Unreleased]` with `Added`/`Changed`/`Fixed`/`Removed`, link definitions). Its first
`Unreleased` section records Skald v1 and this work. `scripts/changelog.py` and its tests come
over from Hulder, renamed.

### Releasing

`scripts/release [--dry-run] [--version <YYYYMMDD-HHMM>]` is Hulder's script with Skald's names
(the repository, the zip, the cask file), step for step: checks (clean tree, `gh` signed in, the
team identity, a new release on `main` level with `origin/main` with `Unreleased` entries, or a
resumable state); the version; the changelog commit and push (with Hulder's recovery rules for an
unpushed release commit); the Release build; `verify-app --team`; `ditto -c -k --keepParent`;
then tag, GitHub release with the changelog section as notes, upload unless already uploaded,
download and checksum the published asset, and update `Casks/skald.rb` in the tap unless it
already has this version and checksum. `scripts/tests/test-release-dry-run` comes over too.

### Homebrew cask

`Casks/skald.rb` in `michaelrigart/homebrew-tap`, rendered from `scripts/skald.rb.template`:
`version`, `sha256`, the release asset `url`, `name "Skald"`, a generic `desc` ("Spelling and
grammar checker for the menu bar"), the repository as `homepage`, `livecheck` on the latest
GitHub release, `depends_on arch: :arm64` and macOS 27, `app "Skald.app", target:
"/Applications/Skald.app"`, `uninstall quit: "com.michaelrigart.skald"`, and `zap` for Skald's
Application Support folder and preferences (the builder lists the paths v1 actually writes).
The Keychain item holding the Claude API key is not removed by `zap`; the README says how to
delete it. Caveats: "Open Anyway" on first launch (not notarized); allow Skald under
Accessibility; model checks need Apple Intelligence turned on.

### Running from the wrong place

Skald only works from `/Applications` (the Accessibility grant belongs to that bundle). At
launch, when its bundle isn't directly in `/Applications`, Skald says so ("Move Skald to the
Applications folder, then open it again") and checks nothing, as Hulder does; the decision is a
pure function of the bundle path, tested for `/Applications`, a subfolder, `~/Applications` and a
build folder. If v1's app shell already does this, the plan reuses it.

### Design sources

- `design/` holds the designer's SVGs from `~/scald` (2026-11-05): `app-icon.svg`, `mark.svg`,
  `mark-on-light.svg`. The delivered PNGs and `.icns` are not committed; they are regenerated.
- `design/menubar.svg` is new: the mark's three bars and check in a single colour (`#000000`),
  on the mark's own view box, for a template image, with a thin gap masked out of the bars
  around the check, which otherwise merges with the middle bar in one colour. The designer
  delivered no menu bar glyph, so this is derived. Michael chose this version, with the gap, from
  the rendered previews (2026-11-06). That file was lost before it was committed; the file in
  `design/` was rebuilt from this description (the check stroked 8 units wide in the mask, a gap
  of about 1 px at 18 px), and Michael approved the rebuilt version from its previews the same day.
- `design/render` (Muninn's variant) regenerates `Skald/Assets.xcassets/AppIcon.appiconset` from
  `app-icon.svg` at every size in its `Contents.json`, and `SkaldMenuBar.imageset` (18 and 36 px,
  `template-rendering-intent: template`) from `menubar.svg`. It needs `rsvg-convert` (Homebrew
  `librsvg`) and says so when it is missing.
- `project.yml` sets `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`; the status item uses
  `NSImage(named: "SkaldMenuBar")` instead of the system symbol, in every state; the state is in
  its tooltip and menu (Michael's decision, 2026-11-06).

### Documentation

- **README** (Skald has none; the repository is public): what Skald does and needs (macOS 27,
  Apple Intelligence for model checks), the Homebrew install with its first-run steps, building
  from source with the ad-hoc override, the limits per app from the feasibility check, and how
  to remove the Keychain item.
- **AGENTS.md:** the release, verify and render commands; that CI signs ad hoc; that
  user-visible changes add a `CHANGELOG.md` entry under `Unreleased`.

### Before the first push

The repository becomes public. Before the first push to `michaelrigart/skald`, the builder checks
the whole history, not only the tip: no secrets (gitleaks, which the push guard also runs), no
machine details in public docs, no real company names or customer text in `Eval/` or the spike
fixtures, and nothing from `.superpowers/` tracked. Anything found goes to Michael before the push.

## Constraints

- Everything in the v1 spec still holds: macOS 27, no entitlements, Hardened Runtime, running
  from `/Applications`, XcodeGen through mise, `SkaldCore` importing only Foundation and
  Observation.
- Pushes from Michael's Mac use his existing git and `gh` credentials.

## Prerequisites (Michael)

- The Personal Team's Apple Development certificate and Apple's WWDR intermediate are in his
  login keychain (used for Hulder and Linger). The certificate's subject, his Apple ID email, is
  embedded in every public release; he accepted this for Linger (2026-11-01).
- `gh` signed in with rights to create `michaelrigart/skald` and push to the tap.

## Delivery

- **Branch:** `feat/skald-distribution`, from `feat/skald-v1` once v1's tasks are done. Its draft
  pull request targets `main` and is rebased onto `main` after v1 merges.
- The repository is created and `main` pushed when the pull requests need a remote.

## Acceptance

1. CI passes on this work's pull request: both suites, the Release build and the verifier.
2. A team-signed Debug rebuild and the Release build keep the Accessibility grant after a
   reinstall, with no new grant; the one grant at the switch from ad hoc is recorded.
3. `scripts/release --dry-run` builds, verifies and packages an Apple silicon zip and prints the
   changelog section it would commit.
4. A Release build contains no probe (`verify-app` passes; a Debug build fails it).
5. A Release build run from outside `/Applications` shows the move message and checks nothing.
6. The menu bar shows the Skald glyph in light and dark menu bars, and Finder and the Dock show
   the app icon.
7. **After v1 and this work merge,** the first release creates the tag, the GitHub release with
   the zip, and the cask; `brew install --cask michaelrigart/tap/skald` installs Skald in
   `/Applications`; after "Open Anyway" and one Accessibility grant, Skald checks text and
   Settings shows the version.
8. At the second release, `brew upgrade` launches without "Open Anyway" and keeps the
   Accessibility grant, or the caveats and README say otherwise.

## Left to the builder

- the scripts' language (shell is fine, as Hulder's);
- the exact Xcode 27 build on the runner and the pinned action versions;
- the cask's caveat wording and the Homebrew symbol for macOS 27;
- how the verifier detects the probe, within the rule above;
- the zap paths, from what v1 writes.
