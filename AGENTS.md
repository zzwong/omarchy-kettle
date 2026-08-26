# AGENTS.md

QML + bash Omarchy bar plugin. No build step; deps are bash and python3.

## QML cache trap

The shell's QML bytecode cache outlives plugin hot-reload. After changing any
`.qml`, `omarchy restart shell` — rescans and file touches are not enough.
Symptom: the live bar disagrees with an isolated `qs -p test.qml` run.

## Dev loop

- Source of truth is this repo. `~/.config/omarchy/plugins/zzwong.kettle/` is
  a git clone of GitHub, moved forward with `omarchy plugin update`.
- Test uncommitted work: rsync over the installed copy (exclude `.git`),
  restart the shell; restore with `git -C <installed> checkout -- .`.
- `omarchy plugin enable` rewrites the shell.json entry and drops settings
  like `herdrWindow` — check before and after.

## Driving it headlessly

- Fake pots: `bin/kettle-emit --agent x --id t1 --state working --cwd /tmp/x`
  (`--state gone` cleans up).
- Panel: `omarchy-shell kettle toggle|open|close|count`; select and jump with
  `wtype -k Down` / `wtype -k Return`.
- Real herdr states: `herdr agent prompt <pane> "..."`, watch
  `herdr api snapshot`.
- Demo screenshots: `grim` on an empty workspace; check the background for
  leaks before committing an image.

## Tests and commits

- `./test/run-tests` (or one group: `./test/run-tests stream`). New behavior
  gets a test in the matching group.
- Commit style per CONTRIBUTING.md, enforced by the hook and CI. Enable once:
  `git config core.hooksPath .githooks`.

## Map

| File | Owns |
|---|---|
| `Panel.qml` | UI, keyboard nav, jump-to-window, IPC surface |
| `PotStore.qml` | pot state machine, model catalogs, pi model lookup |
| `Relay.qml` | remote-event ingestion and its trust boundary |
| `HerdrPoller.qml` / `RemoteHerdrPoller.qml` | local poll / ssh stream |
| `Notifier.qml` | notification guards |
| `bin/kettle-agent-hook` | Claude Code + Codex hook (also pushed to remotes) |
| `bin/kettle-emit` | ingestion contract for any other agent |

## House rules

- Comments explain why; measured claims say how they were measured.
- Validate everything crossing a trust boundary at ingestion — length-capped,
  charset-checked, like its neighbors.
- Per-poll process spawns are a design smell; per-state-change is the budget.
