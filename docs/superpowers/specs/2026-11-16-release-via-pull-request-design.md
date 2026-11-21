# Releasing through a pull request (Skald port) — design

**Date:** 2026-11-16
**Status:** Implemented ([pull request #3](https://github.com/michaelrigart/skald/pull/3), into `feat/skald-v1`; it reaches `main` with [pull request #1](https://github.com/michaelrigart/skald/pull/1))
**Canonical design:** Muninn's
([`michaelrigart/muninn`, `docs/superpowers/specs/2026-11-16-release-via-pull-request-design.md`](https://github.com/michaelrigart/muninn/blob/main/docs/superpowers/specs/2026-11-16-release-via-pull-request-design.md)),
signed off by Michael on 2026-11-16; its "Ports" section names Skald (Muninn's
`fix/release-via-pr` at `a539742`). Its goals, anti-goals, design, tests, documentation and
acceptance apply here unchanged. This document records only how Skald differs.
**Supersedes in part:** Skald's distribution design
(`docs/superpowers/specs/2026-11-05-skald-distribution-design.md`), on the points the canonical
design supersedes in Muninn's: the anti-goal "The release script pushes to `main` only its own
release commit (the changelog section), plus the tag", and, under "Decisions (Michael's)",
"Releasing", the changelog commit's push and "Hulder's recovery rules for an unpushed release
commit".

## Why

Skald's `main` carries the rulesets the canonical design describes (`protect-main` and
`main-merge-owner`, both active). `scripts/release` pushes "Release <version>" straight to
`main`, so Skald's first release would fail at that push, as Tafl's did. Skald has not released
yet: it has no tag, and its first release follows v1's merge into `main`.

## What Skald takes

Muninn's `scripts/release` and `scripts/tests/test-release-dry-run`, as they stand on Muninn's
`fix/release-via-pr` once they pass Codex's pre-merge review, ported whole rather than
reimplemented (Michael, 2026-11-16: "all release scripts should resemble each other as much as
possible"). The plan names the Muninn commit. If Muninn's two files change after it, before the
merges, Skald takes the change too.

Today, with names mapped, Skald's `scripts/release` equals Muninn's on `main` (`56c3e8b`) and its
test differs only as listed below. That still holds after the port.

## Differences from Muninn

Names, as the canonical design allows:

| | Muninn | Skald |
|---|---|---|
| Repository | `michaelrigart/muninn` | `michaelrigart/skald` |
| Temporary folders | `muninn-release.*`, `muninn-release-test.*` | `skald-release.*`, `skald-release-test.*` |
| App, project, scheme | `Muninn.app`, `Muninn.xcodeproj`, `Muninn` | `Skald.app`, `Skald.xcodeproj`, `Skald` |
| Release asset | `Muninn-<version>.zip` | `Skald-<version>.zip` |
| Cask template, cask | `scripts/muninn.rb.template`, `Casks/muninn.rb` | `scripts/skald.rb.template`, `Casks/skald.rb` |
| Tap commit message | `muninn <version>` | `skald <version>` |

The team (`CX4MWR5579`) and the tap (`michaelrigart/homebrew-tap`) are Muninn's.

In the test, besides those names:

- **No zap cases.** Muninn's `zap_is_settings_only` helper and its four cases stay Muninn's.
  Skald's cask has a zap rule of its own, which its test has never checked; the port adds no
  check for it.
- **One fixture string.** Case "a: the section holds only the fixture's text" names a line of
  the repository's own `CHANGELOG.md`: Muninn's "Muninn records calls", Skald's "Skald v1: check
  spelling".

Today Skald's test also pins two refusals Muninn's does not (Skald's `9f02586`): b1 expects the
full "a new release must be cut from main", and b3b refuses a new release from a `main` behind
origin's. Muninn's test takes both in this change (the Muninn session, 2026-11-16), so they are
no longer a difference.

The port is checked by mapping Muninn's names to Skald's in Muninn's two files and diffing them
with Skald's: the diff shows only the differences above.

## Base branch

Skald's release script and its test exist only on `feat/skald-v1`, whose pull request into
`main` (#1, draft) is still open. The port branches from `feat/skald-v1` at `c88dfad`, and its
pull request targets `feat/skald-v1`, so the fix reaches `main` with Skald v1, before its first
release. The Skald session on `feat/skald-v1` keeps working there; it is told when this pull
request merges, so it pulls before its next push.

## Test runs

Michael's global git configuration signs commits and sets `core.hooksPath` to a pre-push secret
scan, which broke Hulder's suite. Muninn's test isolates itself: it turns signing off and gives
every repository it makes its own hooks path, so the global hook never runs inside the suite.
The suite therefore runs under Michael's normal configuration, with no `GIT_CONFIG_GLOBAL`
override, and acceptance 2 is measured that way.

## Documentation

As the canonical design's "Documentation", in Skald's words:

- `README.md`, "Releasing": the release commit goes through a pull request that the script opens
  and merges as admin; `gh` must use a login with the `repo` scope of an admin account; a failed
  run says where it stopped, and `--version` resumes it.
- `AGENTS.md`: the "Release" command line says it pushes a release branch and merges its pull
  request, and the "Distribution design" line under "Releases and CI" also names the canonical
  design and this one.
- The distribution design gains one line under its header pointing here for the release flow. Its
  text is not rewritten.
- No `CHANGELOG.md` entry: nothing changes for users.

`feat/skald-v1` may meanwhile edit `README.md`, `AGENTS.md` and `CHANGELOG.md`. The port touches
only the lines named above.

## Acceptance

1. Muninn's two files, names mapped, differ from Skald's only as described under "Differences from
   Muninn".
2. `scripts/tests/test-release-dry-run` passes on Michael's Mac, every case, and the changelog unit
   tests pass.
3. `scripts/release --dry-run` passes there and creates nothing on git or GitHub.
4. CI passes on the pull request.
5. After v1 merges into `main`, Skald's first real release, run by Michael, lands, tags and
   publishes in one run and ends on `main` level with origin, with no `release/<version>` left.

Cross-repository: the Muninn, Hulder, Linger, Tafl and Skald pull requests are all opened before
any is merged, and Muninn's merges first.
