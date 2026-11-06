# Skald

Skald is a spelling and grammar checker for macOS that lives in the menu bar. It checks what
you type in other apps, in English and Dutch, and in French in its panel, and runs on your
Mac. It underlines issues in the field and offers the correction on a card. Where an app
doesn't tell Skald where the text is, a small badge with a count of the issues sits on the
field instead.

## Features

- Checks as you type in Notes, Mail, Slack and the other apps under
  [App support](#app-support). By default it checks English and Dutch while you type, and
  the on-device model's grammar checks are on for English only: Dutch gets spelling checks.
  French is checked only in the panel. Change this in Settings > Languages with **Check while
  typing** and **Model checks (grammar and spelling)**.
- Underlines an issue in the field, or shows a badge with a count where the app doesn't allow
  that. A card offers the correction.
- A panel, opened with a hotkey (Control-Option-G by default), to fix or rewrite the selection
  or the current paragraph.
- Checks while you type always stay on your Mac. The panel can also use a Mac Studio
  (Settings > Engines > Mac Studio, which takes any Ollama or OpenAI-compatible server), or
  Claude, if you set one up in Settings.
- Terminals, code editors and password managers are off by default. Secure text fields are
  never read.
- Launches at login (you can turn this off in Settings).

## Requirements

- macOS 27 or later, on Apple silicon.
- Skald must run from `/Applications`. From anywhere else it shows "Move Skald to the
  Applications folder, then open it again." and checks nothing.
- The Accessibility permission, which System Settings > Privacy & Security lists as "Device
  Control and Data Access". Skald needs it to read the text you type and to apply a
  correction.
- Apple Intelligence, turned on in System Settings, for the on-device model's checks (English
  by default). Without it Skald checks spelling only.
- To build: Xcode 27 and [mise](https://mise.jdx.dev) for XcodeGen.

## Install

```sh
brew install --cask michaelrigart/tap/skald
```

The cask installs Skald to `/Applications/Skald.app`, whatever `--appdir` says.

Skald is signed with a free developer certificate and is not notarized, so macOS blocks it the
first time you open it. After the first install:

1. Open System Settings > Privacy & Security, find the message about Skald and click
   **Open Anyway**.
2. Allow Skald under System Settings > Privacy & Security > Device Control and Data Access.
3. For grammar checks, turn on Apple Intelligence in System Settings.

Upgrade with `brew upgrade --cask skald`. Releases are signed with the same certificate, and
macOS ties the Accessibility permission to that certificate, so an upgrade should keep the
permission. That hasn't been measured yet; if macOS asks again, repeat step 2. The same goes
for **Open Anyway**: upgrades should not need it, so if macOS blocks one, repeat step 1.

The developer certificate is renewed every year. Whether a renewed certificate keeps the
permission has not been confirmed.

If you built Skald yourself before, quit it and delete every copy first, including the build
in your checkout's `build/`. A build signed differently from the Homebrew one has an old
entry in Device Control and Data Access that can look switched on while it no longer
applies. Remove it there, or run `tccutil reset Accessibility com.michaelrigart.skald`, then
allow Skald again.

## Build and install

To build it yourself, you need the full Xcode. If `xcode-select -p` points at the Command
Line Tools, prefix the `xcodebuild` and `swift` commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

The project is set up to sign with the maintainer's certificate, which you won't have. Add
`CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` to `xcodebuild` to sign ad hoc instead.

```sh
mise trust mise.toml
mise exec -- xcodegen generate
xcodebuild -project Skald.xcodeproj -scheme Skald -configuration Release -derivedDataPath build -destination platform=macOS CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -quiet build
rm -rf /Applications/Skald.app
ditto build/Build/Products/Release/Skald.app /Applications/Skald.app
open /Applications/Skald.app
```

Remove the old app first: `ditto` merges into an existing bundle and would keep stale files.
Quit Skald before you replace it, so that `open` starts the new build instead of bringing the
old one forward.

Start Skald with `open` or Finder: launched from a terminal, macOS gives the Accessibility
permission to the terminal.

An ad hoc build is a different app to macOS every time you rebuild it, so you need to give
the Accessibility permission again, and the old build's entry stays in Device Control and
Data Access without working. Run `tccutil reset Accessibility com.michaelrigart.skald` to
clear it, then allow Skald again.

## Tests

```sh
swift test --package-path Packages/SkaldCore
swift test --package-path Packages/SkaldPlatform27
/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'
```

The tests that use the on-device model run only on a Mac with Apple Intelligence turned on.

## Probe

A Debug build includes a probe that checks how Skald reads and writes text in an app, so a
new macOS or a new version of an app can be checked by rerunning it. Release builds do not
contain it. Build Debug, install it to `/Applications`, then start it with `--probe`:

```sh
xcodebuild -project Skald.xcodeproj -scheme Skald -configuration Debug -derivedDataPath build -destination platform=macOS CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -quiet build
rm -rf /Applications/Skald.app
ditto build/Build/Products/Debug/Skald.app /Applications/Skald.app
open /Applications/Skald.app --args --probe
```

## Releasing

The maintainer cuts a release with `scripts/release`. It needs the signing certificate, so it
runs on the maintainer's Mac, not in CI. It sets the version (the time it starts,
`YYYYMMDD-HHMM`), moves the `Unreleased` entries of `CHANGELOG.md` into that version, builds,
signs, runs `scripts/verify-app`, packages `Skald-<version>.zip`, tags, publishes the GitHub
release and updates the cask. `scripts/release --dry-run` does everything up to the package
and prints the changelog section; `--version <version>` resumes a release that failed part
way. `design/render` regenerates the app icon and the menu bar glyph from the SVGs in
`design/` and needs `rsvg-convert` (Homebrew `librsvg`).

## App support

What Skald can do depends on what each app tells it about its text fields. These were
measured on macOS 27.2.

- **Underlines, and corrections applied in place:** Notes, TextEdit, and text areas in Zen
  (including the comment box on GitLab and the editor on Basecamp). The correction is one
  undo step: Command-Z takes it back. Notes and TextEdit take a correction directly; Zen
  takes it by paste, and Skald puts your clipboard back afterwards.
- **Badge with a count, corrections applied in place:** Slack, Signal, Obsidian and Mail's
  compose window. These apps don't tell Skald where a word is, only where the field is.
  Skald applies a correction by pasting it, and puts your clipboard back afterwards.
- **Badge, Copy only:** Proton Mail. A paste adds a line break there, so the card offers Copy
  and you paste the correction yourself.
- **Panel only:** an app that gives Skald the text but not the field's position gets neither
  underlines nor a badge. Select the text and press the hotkey to use the panel. Where the
  app can't be written to, the panel offers Copy instead of Replace.

Apps and fields not listed here haven't been measured. Skald does only what an app supports,
and says what it can't do there.

## Claude API key

If you give Skald a Claude API key, it keeps the key in your Keychain, under the service
`com.michaelrigart.skald` and the account `claude-api-key`. Removing the key in Settings
deletes it. `brew uninstall --zap` leaves it behind; delete it with:

```sh
security delete-generic-password -s com.michaelrigart.skald -a claude-api-key
```

## Design

- [Skald v1](docs/superpowers/specs/2026-11-02-skald-design.md): what macOS 27 allows, what
  was measured on macOS 27.2, and how Skald works.
- [Distribution](docs/superpowers/specs/2026-11-05-skald-distribution-design.md): signing,
  releases, the Homebrew cask and CI.
