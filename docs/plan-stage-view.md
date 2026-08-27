# Plan: Kettle Stage view

Agent Mission Control: an overlay showing every kettle pot as a live preview
deck — see all agent sessions' screens at once, jump or act. Kettle grows an
`overlay` kind next to `bar-widget`; the deck's visual language is vendored
from [omarchy-stage](https://github.com/zzwong/omarchy-stage).

## Preview source per pot origin

The core design problem: pots come from three origins with different
observability. Each gets the best preview it can support.

| Origin | Preview | How |
|---|---|---|
| Hook pots (Claude Code, Codex, … in own windows) | live video | `pot.windowAddr` → `HyprlandToplevel.wayland` → `ScreencopyView { live: true }` |
| Local herdr pots (panes in one herdr window) | text snapshot | `herdr agent read <paneId>` rendered in themed monospace; ANSI stripped in v1 |
| Remote herdr pots (ssh) | text snapshot, selected slab only | `ssh <host> herdr agent read <paneId>`, throttled; unselected slabs show a metadata card (agent, state, cwd, elapsed) |

Screencopy of herdr pots is wrong by construction — every pane shares one
window, so all previews would show whichever tab is visible. Text reads are
truthful per pane.

### Refresh budget (per AGENTS.md: per-state-change is the budget)

- Screencopy is live only while the overlay is open (`captureSource` gated on
  `opened`, same as Stage).
- Local herdr reads: on open (all pots, one batch), then re-read a pot when
  its `state_change_seq` bumps, plus the selected pot on a 2s timer while
  selected.
- Remote reads: selected pot only, 4s minimum interval, in-flight guard.

## UI

- Carousel-only in v1 (no grid): pots ordered as `PotStore.pots` already
  orders them (local first, then hosts alphabetically). Selected slab
  expands; others are skewed slices — vendor `WsSlab` from Stage, strip the
  workspace/monitor mapping, add a `contentComponent` slot (screencopy |
  text | card).
- Chip on each slab: agent glyph + state tint, reusing KettleMark's
  glyph-first state rules (colour is secondary; `needs-attention` pulses).
- Label bar (Stage's pill row): pot title (`terminal_title_stripped` or hook
  label), cwd tail, elapsed/ran word from `PotStore.label`/`ranWord`.
- Empty state: "Nothing cooking" card, mirrors bar widget's idle glyph.

## Interactions

| Input | Action |
|---|---|
| `←` `→` `Tab` `Shift-Tab` | move between pots |
| `Enter` / click preview | `Panel.jump(pot)` — the existing two-step jump (herdr focus + window raise) moves behind a shared helper both surfaces call |
| `Esc` / click outside | close |
| keyboard priority | vendor Stage's `kbdPriority` + deliberate-hover rules |

Deferred (v3): acting on a pot from the overlay — approve/deny via
`herdr agent send_keys`, prompt via `agent.prompt`. Needs a trust/UX pass;
not in scope until the viewer ships.

## Wiring

- `manifest.json`: `kinds: ["bar-widget", "overlay"]`,
  `entryPoints.overlay: "StageView.qml"`, `keepLoaded: true`.
- IPC: overlay registers open/close/toggle via the shell host
  (`omarchy-shell shell toggle zzwong.kettle` summons the overlay kind).
  Add a `kettle stage` verb on the existing IpcHandler that forwards, so
  `omarchy-shell kettle stage` also works and the bar widget can open it.
- Bar widget: pot click keeps its current jump behavior; a new
  "open stage" affordance (header button in the existing panel popup).
- Suggested bind in README: `SUPER + SHIFT + GRAVE` (Stage holds
  `SUPER + GRAVE`).
- Jump/focus code: extract `focusWindow`/`jump` from Panel.qml into a shared
  `Jump.qml` (or JS lib) used by both Panel and StageView.

## Settings

None in v1. The overlay inherits `herdrWindow` resolution through the shared
jump helper. Candidate v2 keys (same barWidget schema surface): preview
refresh interval, remote reads on/off.

## Testing

- Extract preview-source resolution (pot → screencopy|text|card) into a pure
  JS function; unit-test in `test/` alongside existing groups.
- Manual matrix via `bin/kettle-emit` fake pots (hook path) + real herdr
  panes (text path) + `--host` fakes through Relay (card path).
- QML cache trap: every iteration is `omarchy restart shell` (AGENTS.md).

## Risks / open questions

- `herdr agent read` output size and ANSI: strip escapes v1; confirm read
  cost on large scrollback (`--source recent` default appears bounded).
- Multiple herdr pots re-read on one poll if several seqs bump — batch reads
  behind a single queued Process, never parallel spawns.
- Remote ssh latency can exceed the 4s interval — in-flight guard + stale
  badge ("as of 12s ago") on the card rather than blocking.
- Vendored slab drift vs Stage: accepted; note provenance in a header
  comment with the Stage commit vendored from.

## Phases

1. **Viewer**: manifest overlay kind, deck with hook-pot screencopy + local
   herdr text previews, jump, Esc/gesture close, tests for source
   resolution.
2. **Remote + freshness**: remote selected-slab reads, seq-driven re-reads,
   stale badges.
3. **Actions**: approve/prompt from the overlay (trust pass first).
