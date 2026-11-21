# Changelog

All notable changes to Skald are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are release times,
`YYYYMMDD-HHMM` in the maintainer's local time: a version says when a release was made, not
whether it is compatible with the one before. Each section says what changed.

## [Unreleased]

### Added

- Skald v1: check spelling as you type, on your Mac, in English and Dutch, and grammar with
  Apple's on-device model in English when Apple Intelligence is on. French is checked in the
  panel. Change the languages in Settings. Issues are underlined in the field where an app gives
  Skald the text's position, a badge shows their count, and a card offers the correction.
- A panel, opened with a hotkey, to fix or rewrite the selection or the current paragraph.
- Optional remote engines for the panel: a Mac Studio (Settings > Engines > Mac Studio, which
  takes any Ollama or OpenAI-compatible server), and Claude.
  Checking while you type stays on your Mac unless you turn on Claude for Dutch and French.
- Dutch and French can be checked by Claude while you type: turn on Settings > Languages >
  Check Dutch and French with Claude while typing, with your own Claude API key. Only the
  paragraph your caret is in is sent, whether you type in it or just click into it. Text Skald
  detects as English stays on your Mac, and a very short paragraph is treated as the field's
  language. The menu bar icon shows a cloud while checks go to Claude. A card says when Claude
  found the issue. When Claude can't answer, Skald falls back to your on-device settings and the
  menu says why. Removing the key turns the switch off.
- Each app can be On, This Mac only or Off, in Settings > Apps or with the menu's Keep on This
  Mac. Nothing you type in an app kept on this Mac goes to Claude, and the panel offers only
  This Mac there. The menu's Turn On sets an app to This Mac only when it is off by default or
  Claude checks while typing are on; untick Keep on This Mac to let it use Claude.
- Install with Homebrew: `brew install --cask michaelrigart/tap/skald`.
- Releases are signed with a stable certificate, so the Accessibility permission you give Skald
  should survive updates. Switching from a self-built ad hoc copy needs it once more.
- Skald tells you to move it to `/Applications` when it runs from anywhere else, and checks
  nothing until you do.
- If your Mac lacks Apple's language data for English or French, Skald asks macOS to download
  it the first time it checks that language.
- Issues are underlined in three colours: spelling, grammar and punctuation (punctuation is also
  dotted). The menu has a legend for them.
- The card names the kind of issue, lists the alternatives, and has "Hide suggestions like this".
  Hidden kinds come back from Settings > Suggestions.
- The badge shows its count in every checked field, not only where an app hides the text's
  position.
- Review mode: press Control-Option-R (change it in Settings > Suggestions) to step through the
  issues from the keyboard, accepting or dismissing each one. Esc leaves it. VoiceOver announces
  each step.
- The menu says where Skald can't work: an app it can't read, or one where it can't show issues.
- The badge, the list and the card controls have VoiceOver labels.
- "Pause for 30 Minutes" in the menu, next to "Pause for an Hour".

### Changed

- "Ignore" on a card is now "Dismiss", and "Never flag" is "Add to dictionary".

### Fixed

- Underlines are no longer drawn off the word after you scroll: they hide on a scroll and come back
  at your next edit or caret move. Skald brings them back sooner, once their position has settled,
  in apps whose scroll lag it has measured (none yet).
- A French or Dutch fix such as "Tout les" to "Tous les" is no longer dropped because the word
  also exists in English. A fix that translates an English word still is.
- When Claude rejects your key or limits requests, the panel says why and offers the other
  engines, where it used to say "That didn't work. Try again."
- A card or the badge's list no longer opens at zero size, which showed nothing, about every
  other time.
- A word that spelling and Apple's model both flag, with the same fix, shows once in the badge's
  list and its count instead of twice.
- Launch at login now adds Skald to the login items. It never did on a Mac that had not seen
  Skald before, and Settings said it couldn't.
- Accepting a fix in Mail no longer says "The app didn't show the change" when the text did change.

[Unreleased]: https://github.com/michaelrigart/skald/commits/main
