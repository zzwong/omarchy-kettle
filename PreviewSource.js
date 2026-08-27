.pragma library

// Preview-source resolution for the Stage overlay (docs/plan-stage-view.md,
// "Preview source per pot origin"). Pure data-in/data-out on purpose: the
// three pot origins (hook / local herdr / remote herdr) each support a
// different observability level, and that truth table is exactly the kind
// of thing that quietly drifts if it lives inline in a view. Kept here so
// test/run-tests can exercise the real function instead of a hand-mirrored
// copy.
//
// pot.source is the authoritative origin tag (see PotStore.qml): "agent" is
// a hook pot with its own window, "herdr" is a local herdr pane sharing a
// window with siblings, "rherdr" is the same over ssh. Presence of
// windowAddr/host is a consequence of the source, not used to guess it.
//
// isSelected only matters for remote pots: reading a remote pane costs an
// ssh round trip, so only the selected slab pays for it (plan's "Refresh
// budget" — remote reads are selected-pot-only, throttled elsewhere).
//
// This file also owns the two other pure decisions the refresh budget needs
// (seqRereads, staleLabel below) — same reasoning, kept out of StageView.qml
// so they're testable without live Process/Timer machinery.
function resolve(pot, isSelected) {
  var paneId = (pot && pot.paneId) || ""
  var host = (pot && pot.host) || ""
  var windowAddr = (pot && pot.windowAddr) || ""

  if (pot && pot.source === "agent") {
    // Hook pot: has its own window when windowAddr resolved. Until then
    // (or if it never gets one) there is nothing to show but the card.
    return windowAddr
      ? { kind: "screencopy", paneId: paneId, host: host, windowAddr: windowAddr }
      : { kind: "card", paneId: paneId, host: host, windowAddr: windowAddr }
  }

  if (pot && pot.source === "rherdr") {
    // Remote herdr pane: text read is truthful but costs an ssh round trip,
    // so only pay for it on the slab the user is actually looking at.
    return (isSelected && paneId)
      ? { kind: "text", remote: true, paneId: paneId, host: host, windowAddr: windowAddr }
      : { kind: "card", paneId: paneId, host: host, windowAddr: windowAddr }
  }

  if (pot && pot.source === "herdr" && paneId) {
    // Local herdr pane: screencopy would show whichever tab is visible in
    // the shared window, which is wrong by construction — text is the only
    // truthful per-pane preview (see plan's "Screencopy of herdr pots is
    // wrong by construction").
    return { kind: "text", remote: false, paneId: paneId, host: host, windowAddr: windowAddr }
  }

  // Unknown source, or a herdr-family pot missing the field it needs: no
  // observability, fall back to the metadata card rather than guessing.
  return { kind: "card", paneId: paneId, host: host, windowAddr: windowAddr }
}

// ---- refresh-budget decisions (docs/plan-stage-view.md "Refresh budget") --
// Both functions below are pure so the batching/wording they decide can be
// unit-tested the same way resolve() is, instead of only being exercisable
// by driving live Process/Timer objects.

// Local herdr re-reads are seq-driven, not poll-driven: a pane whose
// `state_change_seq` has not moved since the last time we looked has nothing
// new to show, so re-reading it would just be a poll-rate spawn (the exact
// smell AGENTS.md calls out). `watermark` is the paneId -> seq map captured
// after the previous call; a paneId missing from it is a first sighting
// (e.g. right after the overlay's own open-time batch reset the watermark)
// and is recorded without being queued, because that read is already covered
// by the batch. Everything that actually moved comes back in `toRead` so the
// caller can hand the whole list to one queued Process — several seqs
// bumping in one poll must still be one batch, never parallel spawns.
function seqRereads(pots, watermark) {
  var toRead = []
  var next = {}
  var wm = watermark || {}
  var list = pots || []
  for (var i = 0; i < list.length; i++) {
    var p = list[i]
    if (!p || p.source !== "herdr" || !p.paneId) continue
    var prev = wm[p.paneId]
    if (prev === undefined) {
      next[p.paneId] = p.seq
    } else if (prev !== p.seq) {
      toRead.push(p.paneId)
      next[p.paneId] = p.seq
    } else {
      next[p.paneId] = prev
    }
  }
  return { toRead: toRead, watermark: next }
}

// Remote reads are throttled (4s minimum interval, in-flight guard) so an
// ssh round trip slower than that must not block the UI — the slab keeps
// showing the last text it has and says how old it is instead. `ageMs` is
// the time since the currently displayed text was captured; anything within
// the refresh interval is fresh enough to say nothing about.
function staleLabel(ageMs, intervalMs) {
  if (typeof ageMs !== "number" || !isFinite(ageMs) || ageMs < 0) return ""
  if (typeof intervalMs !== "number" || !isFinite(intervalMs) || intervalMs <= 0) return ""
  if (ageMs <= intervalMs) return ""
  return "as of " + Math.floor(ageMs / 1000) + "s ago"
}
