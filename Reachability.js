.pragma library

// When a remote host has been silent long enough that its pots can no longer
// be trusted — and, the part that bit us, how often we are allowed to say so.
//
// A host that suspends, sleeps, or partitions emits neither a snapshot nor a
// `down` marker, so nothing arriving on the wire can clear its pots. The
// supervisor drops them itself once the silence passes lostAfterMs.
//
// That drop used to re-arm its own clock instead of ending. An ssh
// ControlMaster killed by laptop suspend left the gate firing every two
// minutes for as long as the host stayed away: on 2026-08-27 it fired 13
// times between 12:04 and 12:29, and only stopped because the shell reloaded.
// Every fire after the first dropped a set of pots the first had emptied, so
// the cost was a WARN per host per two minutes, forever.
//
// lostFired is the edge. unreachableSince cannot be, because onExited re-arms
// it on every failed respawn — clearing it would just restart the cycle. Only
// a channel that actually started (reachable(), from onStarted) releases the
// latch, so a host that returns and dies again is dropped again.
//
// Pure data-in/data-out so test/run-tests can exercise the real gate instead
// of a hand-mirrored copy of the arithmetic.

// st: {streaming, unreachableSince, lostFired, lostAfterMs}; now: ms epoch.
// Returns the decision plus the state to carry forward.
function lostGate(st, now) {
    var fire = !st.streaming
            && st.unreachableSince > 0
            && !st.lostFired
            && (now - st.unreachableSince) > st.lostAfterMs
    return {
        fire: fire,
        unreachableSince: st.unreachableSince,
        lostFired: st.lostFired || fire
    }
}

// A channel that started is the only evidence the host is back; `masterAlive`
// and a non-empty herdrPath are capability, not reachability.
function reachable(st) {
    return {
        streaming: true,
        unreachableSince: 0,
        lostFired: false,
        lostAfterMs: st.lostAfterMs
    }
}

// Arm on the first failure only. Later respawn failures must not push the
// deadline out, or a host failing faster than lostAfterMs would never be
// dropped at all. 0 is the reachable sentinel, so it doubles as "not armed".
function unreachable(st, now) {
    return {
        streaming: false,
        unreachableSince: st.unreachableSince === 0 ? now : st.unreachableSince,
        lostFired: st.lostFired,
        lostAfterMs: st.lostAfterMs
    }
}
