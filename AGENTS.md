# AGENTS.md

Operational knowledge for coding agents working on this repo. The README is
the user manual; this file is what a fresh session otherwise rediscovers the
expensive way.

Kettle is an Omarchy (Quickshell/Hyprland) bar plugin: QML + bash, no build
step, no dependencies beyond bash and python3.

## The trap that will eat your session

The shell's QML bytecode cache outlives plugin hot-reload. After changing any
`.qml`, `omarchy restart shell` is the only reliable reload — rescans, file
touches, and the "Local plugin changed, reloading" log line are not. Symptom:
the live bar disagrees with an isolated `qs -p test.qml` run of the same file.

## Dev loop

- This repo is the source of truth. The installed copy at
  `~/.config/omarchy/plugins/zzwong.kettle/` is a git clone of GitHub, moved
  forward with `omarchy plugin update zzwong.kettle` after a push.
- To test uncommitted work live: rsync the repo over the installed copy
  (exclude `.git`), `omarchy restart shell`, and when done restore with
  `git -C ~/.config/omarchy/plugins/zzwong.kettle checkout -- . && omarchy plugin update zzwong.kettle`.
- Preserve the user's widget settings: `omarchy plugin enable` rewrites the
  shell.json entry and drops keys like `herdrWindow`. Check before and after.

## Driving it without a mouse

- Fake pots, any source: `bin/kettle-emit --agent x --id t1 --state working
  --cwd /tmp/x --model some-model` (then `--state gone` to clean up).
- Panel: `omarchy-shell kettle toggle|open|close|count`. It is fully
  keyboard-driven; `wtype -k Down` / `wtype -k Return` selects and jumps.
- Real herdr states: `herdr agent prompt <pane> "..."` on a live pane, then
  `herdr api snapshot` to watch `agent_status` transition.
- Screenshots: `grim` full-screen, `magick -crop` for detail shots. Stage
  demo captures on an empty workspace, and check the background for leaks
  (emails, hostnames, transcripts) before committing an image.

## Tests and commits

- `./test/run-tests` runs everything; one group with e.g.
  `./test/run-tests stream`. New behavior gets a test in the matching group.
- Commit style is enforced (`.githooks/commit-msg`, mirrored in CI). Enable
  once per clone: `git config core.hooksPath .githooks`. Plain-English
  imperative subject ≤ 72 chars, no `feat:`-style prefixes, body explains
  why. See CONTRIBUTING.md.

## Map

| File | Owns |
|---|---|
| `Panel.qml` | UI, keyboard nav, jump-to-window, IPC surface |
| `PotStore.qml` | pot state machine, model-name catalogs, pi model lookup |
| `Relay.qml` | remote-event ingestion and its trust boundary |
| `HerdrPoller.qml` / `RemoteHerdrPoller.qml` | local poll / ssh stream |
| `Notifier.qml` | notification guards |
| `bin/kettle-agent-hook` | Claude Code + Codex hook (also pushed to remotes) |
| `bin/kettle-emit` | public ingestion contract for any other agent |

## House rules

- Comments explain *why*, and a claim that was measured or captured says how.
  The README must not promise what the data cannot keep; the coherence test
  group checks some of this mechanically.
- Everything crossing a trust boundary (relay lines, remote stream, hook
  payloads) is validated at ingestion — keep new fields length-capped and
  charset-checked like their neighbors.
- Anything that spawns per-poll is a design smell; per-state-change is the
  budget.
