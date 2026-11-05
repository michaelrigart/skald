# Skald

A local spelling and grammar checker for macOS 27, living in the menu bar.
Design-record rules (specs, plans, status, commits) are in the global agent instructions.

## Commands

Run all of these outside any agent sandbox, with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` as a prefix: SwiftPM's nested
`sandbox-exec`, the module cache under `/var/folders` and the Xcode build service fail
inside the Claude sandbox, and `xcode-select` points at the Command Line Tools. The system
spell server and Foundation Models are unreachable inside the sandbox too.

- Core tests: `swift test --package-path Packages/SkaldCore`
- Platform tests: `swift test --package-path Packages/SkaldPlatform27`
- Generate the project: `mise exec -- xcodegen generate` (`Skald.xcodeproj` is not tracked)
- Build: `xcodebuild -project Skald.xcodeproj -scheme Skald -configuration Debug -derivedDataPath build -destination platform=macOS -quiet build`
- Without the signing certificate (ad hoc): add `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` to the build.
- Install: `rm -rf /Applications/Skald.app && ditto build/Build/Products/Debug/Skald.app /Applications/Skald.app`
  (`ditto` merges into an existing bundle and would keep stale files)
- Run: `open /Applications/Skald.app`

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
- `Eval/` data is synthetic and holds no real company names.
