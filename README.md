# Kettle

Long-running agent work as simmering pots on your Omarchy bar. Glance to see
what's cooking; get told when something finishes, fails, or needs you. Click a
pot to land in the terminal it's running in.

Kettle knows about **herdr** sessions, **Claude Code**, and **Codex** — including
sessions running in plain terminal windows outside any multiplexer.

## Why

Agent sessions are long, bursty, and easy to lose track of. You kick one off,
switch workspace, and either forget it or compulsively tab back to check. Worse,
an agent blocked on a permission prompt waits indefinitely while you do
something else.

The state that matters is *finished while you weren't looking* and *waiting on
you right now*. Kettle surfaces exactly those.

## States

| State | Meaning | Ticking clock? |
|---|---|---|
| `simmering` | work in progress | yes — the tick is the signal |
| `needs-attention` | blocked on an approval or question | yes — it's measuring **your** latency |
| `ready` | finished, and you haven't looked yet | no |
| `burnt` | failed | no |
| `murky` | agent present but unclassifiable | never shown on the bar |

A finished pot never ticks. A running counter on something that already stopped
reads as "still going", so terminal states show a coarse "just now / 5m ago"
plus how long the run actually took.

### Colours

Omarchy themes expose five palette roles — `foreground`, `background`, `accent`,
`urgent`, `muted` — and there is no success or warning role. So state is carried
by **glyph first, colour second**: `needs-attention` and `burnt` necessarily
share `urgent` and are told apart by shape and by motion (only
`needs-attention` pulses). That also survives colourblindness, a monochrome
theme, and a 15-pixel bar slot.

## Install

```bash
git clone https://github.com/zzwong/omarchy-kettle ~/.config/omarchy/plugins/kettle
~/.config/omarchy/plugins/kettle/bin/kettle-install
omarchy plugin enable kettle right
```

`kettle-install` merges hook entries into `~/.claude/settings.json` and
`~/.codex/hooks.json`, pointing at wherever you cloned the repo. It is
idempotent, preserves your existing hooks and settings, and `--remove` reverses
it cleanly. `--check` reports status without changing anything.

herdr needs no setup — Kettle polls it directly.

## How each source works

**herdr** — polled via `herdr api snapshot` every 2s (backing off to 15s when no
server is running, and waking instantly when the socket reappears). One call
returns every agent, so N sessions cost one process. herdr already distinguishes
`idle` from `done`, where `done` means *finished while its tab was unseen* —
which is precisely the state this widget exists to show. Clicking a herdr pot
focuses its tab, which flips it to `idle`, which clears the pot on the next
poll. The jump **is** the acknowledgement.

**Claude Code / Codex** — the agent reports its own lifecycle through hooks.
Nothing outside a terminal can observe what happens inside one: OSC escape
sequences flow from the process to the terminal emulator and stop there, with no
bus and no way for a third party to subscribe. The agent telling you directly is
the only honest source of state.

## Jumping to a window

Clicking a pot has to find the right window, which is harder than it sounds.

For herdr, `herdr agent focus <pane>` switches herdr's *internal* tab but does
not raise the OS window, so Kettle follows it with a Hyprland dispatch.

For agent sessions, Kettle uses a trick: OSC 2 (set window title) is the one
escape sequence with an externally visible side effect, because the terminal
republishes the title to the compositor. At session start the hook writes a
nonce title, polls `hyprctl clients` until it appears (~50ms), caches the window
address, and lets the agent repaint its title immediately after.

This matters because single-process terminals — `ghostty --gtk-single-instance`,
`foot --server`, kitty single-instance — report **the same PID for every
window**, so walking the process tree cannot tell them apart. The nonce works
regardless.

### `herdrWindow`

herdr sets no window title of its own, so on a single-process terminal there is
no way to identify its window automatically. Set a title substring:

```json
{ "id": "kettle", "herdrWindow": "herdr" }
```

and launch herdr with a matching title, e.g. `ghostty --title=herdr -e herdr`.
On multi-process terminals Kettle finds it automatically and you can leave this
unset.

## Keyboard

The panel is fully keyboard driven.

| Key | Action |
|---|---|
| `↑` `↓` | move the cursor, wrapping at both ends |
| `↵` | jump to the selected pot |
| `Tab` | switch to the adjacent bar panel |
| `Esc` | close |

Hovering a row moves the keyboard cursor to it, so the mouse and the keyboard
can never disagree about what `↵` would do.

Bind the panel itself in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + T", "Kettle", "omarchy-shell kettle toggle")
```

## Settings

Set these on the widget's entry in `~/.config/omarchy/shell.json`:

| Key | Default | Meaning |
|---|---|---|
| `showCount` | `true` | show the live count beside the glyph |
| `notifications` | `true` | desktop notification on state changes |
| `herdrWindow` | `""` | title/class substring identifying herdr's window |

## Notifications

Fire only on transitions into `needs-attention`, `ready`, or `burnt`, and only
when you plausibly cannot already see it. Three guards: focus suppression, a 60s
per-pot cooldown so a flapping agent notifies once a minute rather than once a
flap, and coalescing that turns several near-simultaneous completions into one
summary. The bar always shows true state regardless — notifications are the
escalation, the bar is the truth.

## Requirements

- Omarchy 4 ("Quattro") or newer — the Quickshell plugin architecture
- Hyprland
- Optional: [herdr](https://herdr.dev), Claude Code, Codex

## Known limitations

- **herdr `--remote` is not supported.** It relocates the herdr server and
  attaches a local TUI over ssh, but `herdr api snapshot` accepts no arguments —
  the CLI can only query the local socket. Kettle sees nothing.
- **A blocked pot stays amber until the turn ends.** Neither agent emits an
  event when you *approve* a request, so there is nothing to transition on
  short of hooking every tool call.
- **Hook pots do not survive a shell reload.** They live in memory; herdr pots
  repopulate from the next poll, agent pots reappear on their next event.
- **herdr run durations are accurate to the 2s poll.** Hook-sourced pots are
  exact, so the same work can be reported a second apart by the two sources.

## License

MIT
