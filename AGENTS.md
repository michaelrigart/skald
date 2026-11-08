# Skald

A local spelling and grammar checker for macOS 27, living in the menu bar.
Design-record rules (specs, plans, status, commits) are in the global agent instructions.

## Commands

Run all of these outside any agent sandbox: SwiftPM's nested `sandbox-exec`, the module cache
under `/var/folders` and the Xcode build service fail inside it. Prefix each with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` unless `xcode-select -p` already
points at Xcode. The system spell server and Foundation Models are unreachable inside the
sandbox too.

- Core tests: `swift test --package-path Packages/SkaldCore`
- Platform tests: `swift test --package-path Packages/SkaldPlatform27`
- Generate the project: `mise exec -- xcodegen generate` (`Skald.xcodeproj` is not tracked)
- Build: `xcodebuild -project Skald.xcodeproj -scheme Skald -configuration Debug -derivedDataPath build/dd.noindex -quiet build`
- Release build: the same with `-configuration Release`; `scripts/verify-app` accepts only
  Release builds.
- Without the signing certificate (ad hoc): add `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` to
  either build.
- Install: `rm -rf /Applications/Skald.app && ditto build/dd.noindex/Build/Products/Debug/Skald.app /Applications/Skald.app`
  (`ditto` merges into an existing bundle and would keep stale files)
- Run: `open /Applications/Skald.app`
- Script tests: `/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'` (the
  changelog tool), `scripts/tests/test-release-dry-run`
  (needs the signing certificate and Homebrew: it builds team-signed and runs `brew style`) and
  `scripts/tests/test-verify-app <Release Skald.app> <Debug Skald.app>`
- Verify a built app: `scripts/verify-app [--team <ID>] <Skald.app> [<version>]`. It fails on a
  bad signature, a missing Hardened Runtime flag, `LSMinimumSystemVersion` below 27.0,
  non-empty entitlements, `LSUIElement` not true, a wrong bundle identifier, architectures
  other than exactly `arm64`, or the probe in the executable. With a `<version>` it also checks
  `CFBundleShortVersionString` and `CFBundleVersion`; with `--team` it checks `TeamIdentifier`.
  Give it a Release build: a Debug build contains the probe.
- Release: `scripts/release [--dry-run] [--version <YYYYMMDD-HHMM>]`, on Michael's Mac only (it
  needs the signing certificate and pushes). Use `--dry-run` to check it; never run it for real
  unless Michael asks. `--version` resumes a failed release.
- Regenerate the app icon and menu bar PNGs from `design/app-icon.svg` and
  `design/menubar.svg`: `design/render` (needs `rsvg-convert`, Homebrew `librsvg`)

## Releases and CI

- A user-visible change adds an entry to `CHANGELOG.md` under `## [Unreleased]`, under `Added`,
  `Changed`, `Fixed` or `Removed`. `scripts/release` moves it into the release.
- CI (`.github/workflows/ci.yml`) runs on `xcode-27` and signs ad hoc, because the certificate
  stays on Michael's Mac. It builds with `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`, as anyone
  without the certificate does.
- Distribution design: `docs/superpowers/specs/2026-11-05-skald-distribution-design.md`.

## Rules an agent gets wrong

- `SkaldCore` imports only Foundation and Observation. No frameworks there. macOS-27-specific
  and private APIs, and `#available`, belong in `SkaldPlatform27`; the app target may use
  AppKit and SwiftUI.
- Text offsets are UTF-16 code units (`TextRange`), never `Character` counts.
- Skald must run from `/Applications`. Launch it with `open`: launched from a terminal,
  macOS gives the Accessibility grant to the terminal.
- Builds are signed with Michael's Personal Team (Apple Development, team `CX4MWR5579`), so the
  Accessibility grant should survive rebuilds (confirmed for Hulder, which signs the same way).
  Switching from an ad hoc build to a team-signed one needs the grant once. Ad hoc builds
  (`CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`, for anyone without the certificate) need the grant
  again after every rebuild.
- A bare `log` is a zsh builtin. Use `/usr/bin/log`; the subsystem is
  `com.michaelrigart.skald`.
- Every `xcodebuild` run that compiles (`build`, `test`, `archive` and the like) passes a
  `-derivedDataPath` that ends in `.noindex`: Spotlight skips those folders, so builds never
  show up in Spotlight or Alfred. The default is `build/dd.noindex`; a parallel or scratch
  build uses `build/dd-<name>.noindex`.
- `Eval/` data is synthetic and holds no real company names.
