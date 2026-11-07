# CLAUDE.md: meetingbox

Rules for any AI agent (Claude, Codex) working in this repo. `AGENTS.md` is a symlink to this file.

## What this is
An on device meeting capture tool for macOS: press a key, have the meeting, press it again, get the recording, a transcript and minutes. Nothing leaves the Mac. The main program is the bash script `meetingbox`; the recorder and transcript merger are Swift in `native/`.

## Start here
1. `STATUS.md` first: current state, next actions, blockers.
2. `README.md`: how it installs and works.
3. `docs/superpowers/specs/` for the design, `docs/superpowers/plans/` for the build plans.

## Build, test, install
- Install and setup: `./install.sh`, which hands over to `meetingbox setup`. macOS only.
- Native code builds with `swiftc` only (no SwiftPM, no Xcode project), done by setup.
- Tests: `bash tests/run.sh` (runs `native/tests/run.sh` when present, then every `tests/test_*.sh`). The native tests need a Mac with `swiftc`.
- There is no deploy. Users fetch from `main` through `install.sh`, so anything merged to `main` ships.

## Design line
- One script checks prerequisites and installs them. Never ask the user to install anything by hand.
- Nothing leaves the Mac: no accounts, uploads or cloud calls.
- Delete only what setup recorded in `~/.meetingbox/installed`. Never delete a meeting folder.
- The script runs under `set -euo pipefail` on bash 3.2.

## Rules
- British English.
- No em or en dashes in prose.
- Never paste tokens or keys into chat, commits or pages.
- No AI attribution trailers in commit messages.
- Rewrite `STATUS.md` before stopping.
