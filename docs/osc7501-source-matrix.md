# OSC 7501 source and lifetime matrix

Investigation for [#23](https://github.com/zzwong/omarchy-kettle/issues/23).
Source review only, 2026-11-16. No Core installation, running endpoint, Linux
desktop route, SSH/multiplexer compatibility or Kettle integration was tested.
This document authorizes no installation, connection, migration or replacement.

## Fixed sources

- Kettle: [2613f7383e566b4afd372d1ade4bd088b7b50db4](https://github.com/zzwong/omarchy-kettle/tree/2613f7383e566b4afd372d1ade4bd088b7b50db4).
- Core: [dfde1504b29ee046dee61d5ac9635724dcad2c84](https://github.com/herdrdev/herdr-core/tree/dfde1504b29ee046dee61d5ac9635724dcad2c84).
  Both its [current OpenRPC schema](https://github.com/herdrdev/herdr-core/blob/dfde1504b29ee046dee61d5ac9635724dcad2c84/schema/hc.openrpc.json)
  and [released schema](https://github.com/herdrdev/herdr-core/blob/dfde1504b29ee046dee61d5ac9635724dcad2c84/schema/released.openrpc.json)
  identify version 0.1.21, protocol generation 1. The
  [protocol guide](https://github.com/herdrdev/herdr-core/blob/dfde1504b29ee046dee61d5ac9635724dcad2c84/schema/README.md)
  calls the API preview. A schema version is not installed-binary evidence.
- Core's [README](https://github.com/herdrdev/herdr-core/blob/dfde1504b29ee046dee61d5ac9635724dcad2c84/README.md)
  documents Linux x86_64/aarch64 static builds. Availability is not an observed
  installation, artifact verification or successful Linux route.

## Existing Kettle is a different API

| Existing path | Exact source contract | Core is not a replacement command |
| --- | --- | --- |
| Local poll | [HerdrPoller.qml](https://github.com/zzwong/omarchy-kettle/blob/2613f7383e566b4afd372d1ade4bd088b7b50db4/HerdrPoller.qml) invokes `herdr api snapshot`, reads `result.snapshot.agents` and `focused_pane_id`. | Core returns terminal records, not this agent/focus snapshot. |
| Remote stream | [kettle-herdr-stream.sh](https://github.com/zzwong/omarchy-kettle/blob/2613f7383e566b4afd372d1ade4bd088b7b50db4/bin/kettle-herdr-stream.sh) polls that same legacy API and emits its bounded projection. | Existing S/H/D transport and reachability semantics must remain intact. |
| Remote idle wake | [RemoteHerdrPoller.qml](https://github.com/zzwong/omarchy-kettle/blob/2613f7383e566b4afd372d1ade4bd088b7b50db4/RemoteHerdrPoller.qml) uses `herdr agent list` only to wake an idle channel. | This is not the main remote ingestion command. |
| State and acknowledgment | [PotStore.qml](https://github.com/zzwong/omarchy-kettle/blob/2613f7383e566b4afd372d1ade4bd088b7b50db4/PotStore.qml) consumes legacy pane status/sequence. The [README](https://github.com/zzwong/omarchy-kettle/blob/2613f7383e566b4afd372d1ade4bd088b7b50db4/README.md) describes focus acknowledging herdr completion. | Core status is program-reported; no equivalent focus acknowledgment is established here. |

Do not replace legacy pollers, hooks, pi, kettle-emit, remote relay or navigation.
Open navigation #22, duration #24, line-guard #25, notification #26 and Stage #2
remain separate work. This investigation adds no dependencies between them.

## Candidate Core contract

The pinned OpenRPC schema and protocol guide above describe:

| Surface | Available fact | Adapter constraint |
| --- | --- | --- |
| `hello` | Generation, version, supported methods/features, permanent `core.id` (reset when state is wiped). | Bind source identity to an explicitly selected endpoint and handshake. A display hostname is not identity or authorization. |
| `terminal.list` / `terminal.get` | Terminal address, lifecycle, optional root status, child `records`, `reported`, `turn`, foreground facts. | Default list omits finished terminals; fields with defaults may be absent. Terminal address is not a legacy pane or conversation ID. |
| `events.subscribe` | Subscription snapshot with `seq`, then event notifications. Plain mode becomes notification-only. | Keep command and event connection responsibilities explicit; do not issue ordinary calls on a notification-only stream. |
| `status` event | Complete replacement of root `status`, all `records`, and `reported`. | Do not merge omitted old child records back into the new state. Preserve blocked kind (permission/question/auth) when supplied. |
| `missed` | Fresh snapshot and sequence boundary. | Replace from snapshot; discard queued events at or below its sequence. Absence is not a fabricated completion. |
| Reconnect | Sequence restarts with each Core process; a fresh snapshot is required. | Core ID persists across ordinary restarts, so core ID alone is not a stream epoch. Retire the prior connection's sequence/queued events. |
| Remote terminals | Names such as `machine/t7`; reconnect can resend `created` as replacement. | Do not reuse the legacy pane-ID validator or treat slash-containing IDs as paths. Remote aliases and authority need separate qualification. |
| Numeric/string fields | Sequence/turn are uint64; status words are strings; progress schema allows uint8 while its description says 0..100. | Schema validity alone is insufficient. Define bounded safe decoding before QML Number conversion; do not silently round large sequence IDs or interpret an unknown state as done. |

The protocol's heartbeat describes stream liveness, not producer activity.
A producer's silence is not completion. Status text, app labels, record IDs and
foreground metadata never authorize commands or desktop navigation.

## Lifetime mismatch requiring a decision

The pinned [status implementation](https://github.com/herdrdev/herdr-core/blob/dfde1504b29ee046dee61d5ac9635724dcad2c84/crates/herdr-core/src/status.rs)
stores reports and implements explicit clear of a record and its descendants.
Its `reset` removes **all** root and child records. The protocol guide says
status clears before a terminal's `finished` event. This includes reported
done/error, whereas Kettle #23 requires done/error to survive terminal lifetime
clearing.

Do not infer absence of shell-return handling solely from the still-open
[Core #181](https://github.com/herdrdev/herdr-core/issues/181). The pinned
[foreground watcher](https://github.com/herdrdev/herdr-core/blob/dfde1504b29ee046dee61d5ac9635724dcad2c84/crates/herdr-core/src/foreground.rs)
already resets status when a tracked foreground returns to a recognized
interactive shell root. Command/script wrappers are deliberately excluded.
[Commit 72ab4ae](https://github.com/herdrdev/herdr-core/commit/72ab4ae45b7bb1a704e1729317d6ae6f080d5570)
records this change. That source presence does not prove all #181 scenarios
fixed or demonstrate a real Linux route.

An adapter cannot recover a done/error report that Core cleared before its first
snapshot or during disconnection. Locally retaining an observed completion
would introduce retention, expiry and acknowledgment policy; it is not a lossless
translation supplied by this API. Neither silently retaining it forever nor
silently dropping it resolves #23. App inheritance, blocked-child precedence,
duplicate-producer identity and remote ownership also require explicit contracts.

## Bounded next step and fixture plan

First select the lifecycle contract: obtain upstream evidence for the required
retention semantics, or explicitly review a narrower Kettle policy and its
unrecoverable-history limitation. Do not implement retention by inference.

Then define a separate opt-in source adapter and add pure tests against that
actual production reducer in the existing test harness. Tests should use
fictional JSON records only, with no socket, process, installation or network:

| Case | Required assertion or unresolved prerequisite |
| --- | --- |
| Initial snapshot and status replacement | Keep terminal identity; replace all status fields/child records without mutating input. |
| Concurrent terminals / duplicate producers | No cross-terminal collision; no hook/herdr deduplication without an explicit mapping. |
| Blocked child under idle root | Exercise the reviewed precedence and app-inheritance contract, not root-only suppression. |
| Done/error followed by reset/finished | Test the selected retention/acknowledgment policy; currently unresolved. |
| Missed snapshot / reconnect / Core restart | Discard superseded events; establish a new stream epoch; never resurrect old live records. |
| Resent created / removed / restarted / lost | Separate record replacement, removal and recoverable loss; no guessed completion. |
| Unknown words, malformed fields, oversized text and unsafe uint64 | Reject or quarantine according to the reviewed contract before state changes; no false ready state. |
| Disconnect after an unobserved completion | Expose unavailable history rather than inventing an observed result. |

No executable reducer or synthetic implementation is added by this document:
testing a disconnected imitation would not qualify Kettle. A later bounded live
Linux/Hyprland test must separately establish the selected installed Core version,
endpoint identity, actual event/lifetime behavior and cleanup. SSH/multiplexer
support and desktop navigation remain unqualified until independently exercised.

