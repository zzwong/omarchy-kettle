# Desktop navigation adapters

The executing agent and the application owning its conversation are separate
identities. A Codex provider inside another host application must navigate to
that host's existing conversation, not to Codex Desktop. Missing tty, cwd,
agent kind, and focused window do not establish desktop ownership.

This layer implements local Linux/Hyprland navigation. It adds no polling,
listener, runtime dependency, app installation, or lifecycle subscription.
Existing terminal and herdr transports remain independent.

## Responsibilities

| Component | Responsibility |
|---|---|
| Hook or future native producer | Prove ownership, map provider session to app thread, emit lifecycle events |
| `Navigation.js` | Static descriptors, normalized targets, scoped identity, request/receipt validation |
| `PotStore.qml` | Lifecycle, event revision, informational failures, snapshot acknowledgment |
| `Navigator.qml` | One supervised attempt, coalescing, busy/error feedback, cancellation, receipt policy |
| App helper | Open the exact existing chat through the app's verified interface |
| `lib/kettle_navigation.py` | Bounded transport execution and cursor-preserving, verified window focus |

Helpers return evidence after focus. They never acknowledge pots. The controller
acknowledges only the selected finished snapshot; live/blocked work survives.
Every accepted pot update replaces its snapshot and increments an internal
revision, including repeated completions. A removed/recreated pot cannot match
an old receipt. App/window closure is not evidence that desktop work ended.

## Production capability matrix

| Owner | Lifecycle evidence | Existing-chat navigation | Focus | Receipt policy |
|---|---|---|---|---|
| `codex-desktop`, `default` | Installed local Codex hooks plus exact `Codex Desktop` origin marker | Registered `codex://threads/<UUID>` URL handler | Allowed `chatgpt`/`codex` class, unambiguous address, verified active window | `opened` |

Codex is the only shipped entry. Its baseline was qualified in #20 and confirmed
by the maintainer using the installed build. The migration's live report is
recorded below. This is a tested mechanism, not a compatibility promise for all
past/future app versions. Requalify changes to the app handler or window model.

`opened` means the URL command accepted an exact-thread request and Kettle
resolved/focused an allowed window. It is **not** an independent app receipt
that the conversation was selected or read. A future adapter using `selected`
must provide the matching app thread ID (and instance, when supplied) from a
native receipt. A workspace-open or window-activation API cannot qualify as
either existing-chat receipt.

## Event contract

```json
{
  "source": "agent",
  "agent": "codex",
  "id": "11111111-1111-4111-8111-111111111111",
  "state": "finished",
  "navigation": {
    "version": 1,
    "kind": "desktop-chat",
    "app": "codex-desktop",
    "instance": "default",
    "threadId": "11111111-1111-4111-8111-111111111111"
  }
}
```

The target has exactly these five fields. Version is numeric `1`, kind is
`desktop-chat`, app matches `[a-z][a-z0-9-]{0,47}`, instance matches
`[A-Za-z0-9][A-Za-z0-9._-]{0,63}`, and thread ID is a string of at most 128
characters satisfying the selected descriptor's actual upstream grammar.
V1 also requires `[A-Za-z0-9][A-Za-z0-9._:-]{0,127}` and forbids `..`; URL,
control and shell syntax are never accepted. Wider upstream grammars require
an explicitly revised contract or a verified opaque-ID mapping.
Codex requires a UUID. Only shipped app/instance entries are actionable.
Targets never contain commands, paths, credentials, URLs, ports, or sockets.
Ingestion rebuilds the allowed object rather than retaining raw metadata.

Producers can use `kettle-emit --navigation '<target JSON>'` alongside the normal
agent/id/state arguments. That argument must be an object of at most 2048 UTF-8
bytes; actionable validation happens at ingestion. This allows unknown owners
to report lifecycle without advertising unsupported navigation. All events for
a desktop run, including `register`/`gone`, must carry the same owner/instance
and canonical producer session ID.

Invalid, unknown, or conflicting targets retain otherwise valid lifecycle data
as informational pots. They suppress window-focus acknowledgment and terminal
fallback; clicking shows a bounded error with a retry path. Desktop metadata
on remote events is ignored, and `Relay.sanitize()` rebuilds its event without
that metadata. Remote lifecycle/window navigation keeps its existing path.

The hook emits both the new target and legacy `desktopThread` for at least one
release after this change. Kettle also accepts old #20 events: agent must be
Codex, desktop UUID must equal session ID, and host must be local. Both fields
must agree when present; conflicting ownership produces no actionable target.
Explicit application targets are independent of provider kind.

The known default Codex hook mapping keeps `agent:<session>` keys so existing
notification actions still resolve. Other explicit owners use
`agent:desktop:<app>:<instance>:<encoded producer-session>` keys, preventing
owner/instance collisions. Legacy terminal/remote keys remain unchanged.
The two synthetic adapters test this distinction without entering production.

Native/hook deduplication is the producer's responsibility before ingestion:
use one authoritative producer and an explicit mapping to the same canonical
session ID. Do not merge by cwd, provider, or focus. There is no native bridge
or cross-key adoption in this phase. A future bridge needing adoption must add
atomic migration and notification-key alias handling with its own tests; it
must not silently overwrite an unrelated legacy pot.

## Helper protocol and limits

The descriptor supplies a shipped helper basename. The controller launches
`[pluginDir + "/bin/" + helper, JSON.stringify(request)]`, without a shell.
The request has exactly `version: 1`, a Kettle-generated `requestId` matching
`[A-Za-z0-9_-]{1,64}`, and a validated `target`. The helper rejects extra argv,
extra fields, and requests exceeding 2048 UTF-8 bytes before any transport call.

Success is one JSON object, followed by a newline:

```json
{"version":1,"requestId":"jump_1","ok":true,"resolution":"opened","window":"0x1234"}
```

For `selected`, also include `selectedThreadId` equal to the request's thread;
an optional `instance` must match. An adapter requiring `selected` cannot
downgrade to `opened`. Success requires zero exit status and a canonical
`0x`-prefixed, 1–16 digit hex address. The helper checks allowed window identity
before focus, dispatches focus and cursor restoration in one batch, then
requires that address/class to be active. Cursor acquisition/dispatch/verification
failure is failure, not permission to acknowledge a pot.

Failure exits nonzero with `version`, `requestId`, `ok: false`, `code`, and a
control-character-free message of at most 160 characters. Error codes are
`unsupported`, `owner-conflict`, `invalid-target`, `app-unavailable`,
`authentication-required`, `thread-unavailable`, `window-ambiguous`,
`transport-failed`, `timeout`, `busy`, or `cancelled`. Malformed output,
request mismatch, exit/payload disagreement, extra fields, and output exceeding
4096 bytes all preserve the pot. The UI uses fixed messages, not helper text.

One desktop attempt runs globally. The same target coalesces; a different
target gets `busy`. There is no queue. The helper has one 9.5-second monotonic
budget, leaving cleanup time within the controller's 9.8-second deadline plus at most 0.2 seconds of cleanup. It
caps compositor reads at 40, individual transport timeouts at 2 seconds (URL
opener: 5), compositor JSON at 256 KiB and opener/dispatch output at 4 KiB.
No transport stderr reaches user diagnostics. Only direct helper-owned command
processes are terminated, never an app/agent process group. Cancellation sends
SIGTERM; the controller retains a short draining interval before allowing a
retry and forces a stuck helper to stop. Reload invalidates the snapshot and
terminates the helper. A click may already have activated the app before
cancellation; cancellation cannot undo that, but cannot acknowledge work.

## Adding an adapter

1. Establish positive local ownership evidence and a provider-session to
   existing-app-thread mapping. Record source commit, release/build/channel,
   platform, inheritance evidence, fork/resume/concurrent behavior, and instance
   identity. Keep private transcripts and credentials out of fixtures.
2. Verify an externally callable existing-chat mechanism. Prefer a registered
   URL, documented installed CLI, or authenticated native socket/API. Creating
   a session, changing backend execution, opening a workspace, browser scraping,
   or guessing a window is insufficient. Instance endpoints come from trusted
   local configuration, never events. Add configuration/schema only when a
   real adapter requires it; v1 supports only the default Codex instance.
3. Add a static descriptor in `Navigation.js`: helper basename, exact ID grammar,
   allowed instance aliases, and minimum receipt policy. Do not register a
   candidate until qualification is available. Add an app helper using the
   shared runner/validation, or an equivalently bounded implementation.
   `serve()` currently emits `opened`; a selection-confirming helper must emit
   its matching native receipt rather than reuse that weaker convenience path.
4. Make the producer emit the canonical target on every event. Do not add
   provider/app branches to Panel or PotStore. Keep lifecycle subscription
   separate; if needed later, use one bounded persistent bridge per instance
   with ordering/reconnect/dedup tests, not per-poll subprocesses.
5. Add redacted fixtures and transport/contract tests for grammar, instance
   mapping, malformed/oversized output, auth/thread/window errors, timeout,
   reconnect if relevant, and no-create navigation. Test the common controller
   with the adapter's receipt policy. `./test/run-tests desktop` runs Python
   transport tests and actual Quickshell contract/controller/store tests.
6. Live-qualify before advertising support. Update the capability matrix and
   setup/remove/update instructions with exact versions and limitations.

The production registry has no configuration/module loader for arbitrary
adapters. The synthetic descriptors in `test/navigation-contract.qml` use a
`task_*` ID with two instances and an integer ID with a selection receipt;
they are arguments to pure contract functions and injected into a copied
registry inside the isolated controller test. Both run through the real
controller with stubbed helpers. Neither is a shipped registry entry or an
application integration.

## Optional candidates: source reconnaissance, 2026-09-30

These are examples, not required deliveries or a fixed registry. Files were
read through `gh api` at pinned commits; no repositories were cloned and no
apps installed. Source interfaces still require release-specific live testing.

| Example | Findings | Gate for a future integration |
|---|---|---|
| Claude Desktop Code tab | Public [Claude Code repository](https://github.com/anthropics/claude-code/tree/732e167ee9d71296b4b63d6f529ac1334513826a) contains distribution/docs rather than Desktop implementation. [Official desktop docs](https://code.claude.com/docs/en/desktop#shared-configuration) describe shared hooks/settings. | Verify inherited local ownership marker, desktop/provider session mapping, and external exact-session opener. Chat/Cowork remains separate scope. |
| T3 Code | At `c2fa9fc911daeac97df4760f95fc57dca42b84c8`, [activation schema](https://github.com/pingdotgg/t3code/blob/c2fa9fc911daeac97df4760f95fc57dca42b84c8/packages/contracts/src/desktopAppActivation.ts) accepts `open-workspace`, not an existing thread ID. [Renderer handler](https://github.com/pingdotgg/t3code/blob/c2fa9fc911daeac97df4760f95fc57dca42b84c8/apps/web/src/desktopAppActivation.ts) can create a project and opens a **new** thread. [Native control socket](https://github.com/pingdotgg/t3code/blob/c2fa9fc911daeac97df4760f95fc57dca42b84c8/apps/desktop/src/app/DesktopAppActivation.ts) uses its own request/response/deadline contract. | Need externally callable selection of an existing app thread, environment/instance mapping independent of provider ID, and a tested receipt. Do not use this workspace activation API for Kettle chat jumps. |
| bb/getbb | At `84bbff534847ed75705d6face7e4bdff72fe4513`, [package docs](https://github.com/get-bb/bb/blob/84bbff534847ed75705d6face7e4bdff72fe4513/packages/bb-app/README.md) expose `BB_SERVER_URL`/`BB_THREAD_ID` to app-launched scripts; provider-hook inheritance is not established. [Desktop second-instance handler](https://github.com/get-bb/bb/blob/84bbff534847ed75705d6face7e4bdff72fe4513/apps/desktop/src/main.ts) focuses the first window or creates a window at its current URL. [Websocket client protocol](https://github.com/get-bb/bb/blob/84bbff534847ed75705d6face7e4bdff72fe4513/apps/server/src/ws/client-protocol.ts) supports subscriptions. | Verify desktop exact-thread opener, authoritative thread/instance ownership, hook/native dedup, authenticated lifecycle ordering and actual receipt. A server subscription does not establish UI selection. |

These findings motivated distinct owner/provider IDs, instance scoping,
per-owner grammars, correlated requests and honest receipt strengths. They do
not justify speculative deep links, environment autodetection, URL injection,
or pre-registered handlers. Any application can qualify through the same recipe.

## Community qualification checklist

- Record exact app build/channel, platform, Kettle commit, registered handler,
  descriptor grammar and receipt strength. Record independently configured
  instances and credentials requirements without publishing their values.
- Use two existing chats in the same app window, and concurrent instances or
  windows where supported. Verify each jump selects its exact existing chat
  without creating a project/session/turn. App logs can corroborate routes but
  do not become the runtime selection receipt.
- Start on a different workspace; verify allowed-window focus and pointer
  preservation. A title-only match, wrong class, or ambiguous inactive windows
  must fail safely. Verify closed-app behavior against the app's real handler.
- Click finished, working and blocked pots. Shared focus must clear none;
  success clears only the selected finished snapshot. Repeat same-state
  events, start another turn, remove/recreate a pot, and let old receipts arrive.
- Check missing handler/app, malformed/oversized receipt, unavailable thread,
  auth errors, wrong instance, transport/focus failure, timeout, busy and retry.
  Unsupported future cases stay unsupported until a tester supplies evidence.
- Reload/cancel during navigation. No app/agent should be killed. Closing an
  app or losing a lifecycle socket must not invent completion or end work.
- Run the full suite, report skips, and restore temporary plugin/config changes.
  Restart the shell after QML edits; hot reload alone can keep stale bytecode.

## Setup, update, removal and troubleshooting

Install the normal Codex hooks (`bin/kettle-install`) and the desktop app's
registered `codex://` handler. No adapter setting is required. Update Kettle with
`omarchy plugin update zzwong.kettle --yes`, then `omarchy restart shell`.
Use `bin/kettle-install --remove` to remove Kettle's installed agent hooks;
it leaves unrelated hooks intact. No app database, daemon or credentials are managed here.

For a failed jump, the panel reopens with a concise error; retry the row after
the cause is resolved. Unknown apps/instances stay informational. For Codex,
check `xdg-mime query default x-scheme-handler/codex`, that the actual window
class is `chatgpt`/`codex`, and that new hooks run the current installed plugin.
Activate the intended app window before retrying ambiguous multi-window jumps.
Do not paste raw helper requests, app logs, credentials or chat IDs into a
public report. Include app/Kettle versions and the fixed error category instead.

## Migration verification

Verified on 2026-09-30 on Arch Linux, Hyprland `0.56.2-2`, Quickshell `0.3.1-1`,
and `openai-codex-desktop 26.928.20755-1` (app build 12246). The source review
above is separate from this installed-app qualification.

- Temporarily copied the draft into the installed plugin and restarted the
  shell. Used two existing chats in the same allowed app window with synthetic
  completion events through the hook and local IPC; no prompts were submitted.
- Requested chat B then chat A. App log `ownerRoutePath=/local/<chat>` entries
  corroborated both requested existing routes at 16:40:23 and 16:42:04 UTC;
  additional switches were recorded during the focus/retry checks. These are
  manual evidence, not the adapter's runtime receipt.
- From workspace 3, an installed IPC jump returned focus to workspace 2.
  After correcting pre-URL cursor capture, the helper and installed jump both
  preserved the measured pointer coordinates. The selected finished key
  subsequently returned `gone`; the other key remained jumpable until selected.
- A controlled helper returned a correlated `transport-failed` receipt/nonzero
  exit. The same finished key remained jumpable on another failure. Removing
  the test failure flag allowed the real adapter to retry; only then did that
  key return `gone`. Transport/window/deadline/stale-result failures are also
  exercised automatically with stubs.
- Restored the installed clone to merged #20, removed only temporary added
  files, restarted the shell, and verified a clean installed tree and identical
  `shell.json` checksum. The draft remains in the source repository/PR.

The full-suite result is recorded in the draft PR. `desktop` includes actual
Quickshell store/controller execution, two synthetic owners with distinct
instance/ID/receipt contracts, and Python helper transports. Additional apps,
closed-app startup, multiple real windows, authentication receipts, and native
lifecycle bridges remain unqualified; their automated failure fixtures do not
claim live support.
