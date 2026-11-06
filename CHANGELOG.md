# Changelog

All notable changes to Skald are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are release times,
`YYYYMMDD-HHMM` in the maintainer's local time: a version says when a release was made, not
whether it is compatible with the one before. Each section says what changed.

## [Unreleased]

### Added

- Skald v1: check spelling as you type, on your Mac, in English and Dutch, and grammar with
  Apple's on-device model in English when Apple Intelligence is on. French is checked in the
  panel. Change the languages in Settings. Issues are underlined in the field, or shown as a badge with a count where an app doesn't
  give Skald the text's position, and a card offers the correction.
- A panel, opened with a hotkey, to fix or rewrite the selection or the current paragraph.
- Optional remote engines for the panel: a Mac Studio (Settings > Engines > Mac Studio, which
  takes any Ollama or OpenAI-compatible server), and Claude.
  Checking while you type always stays on your Mac.
- Install with Homebrew: `brew install --cask michaelrigart/tap/skald`.
- Releases are signed with a stable certificate, so the Accessibility permission you give Skald
  should survive updates. Switching from a self-built ad hoc copy needs it once more.
- Skald tells you to move it to `/Applications` when it runs from anywhere else, and checks
  nothing until you do.

[Unreleased]: https://github.com/michaelrigart/skald/commits/main
