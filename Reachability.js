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
// the standing cost was a WARN per host per two minutes.
//
// lostFired is the edge. Its release is deliberately not "the clock says so"
// but "a channel started" — see reachable(), including what that does not mean.
//
// Pure data-in/data-out so test/run-tests can exercise the real gate instead
// of a hand-mirrored copy of the arithmetic.

// st: {streaming, unreachableSince, lostFired, lostAfterMs}; now: ms epoch.
function lostGate(st, now) {
    var fire = !st.streaming
            && st.unreachableSince > 0
            && !st.lostFired
            && (now - st.unreachableSince) > st.lostAfterMs
    return {fire: fire, lostFired: st.lostFired || fire}
}

// From the channel's onStarted. Note what that does and does not mean: the
// channel's argv[0] is `bash` (RemoteHerdrPoller.qml:176), which always execs,
// so onStarted fires on every respawn whether or not ssh reached anything.
// Releasing here means "we tried again", not "the host answered".
//
// That is also why a host failing faster than lostAfterMs is never dropped:
// each respawn zeroes the clock before it can mature, and backoff caps at 60s,
// below the 120s gate, so the window never opens. Measured on a 7-minute run
// against an unresolvable host with masterAlive forced true: 0 drops, armed
// age never above ~65s. Pre-existing and tracked separately — releasing on a
// received line rather than on a spawn is the honest fix.
function reachable(st) {
    return {
        streaming: true,
        unreachableSince: 0,
        lostFired: false,
        lostAfterMs: st.lostAfterMs
    }
}

// Arm on the first failure only, so a burst of failed respawns cannot push the
// deadline out. With the wiring above reachable() has always zeroed the clock
// first, so the else-branch does not run today; it is kept because the guard
// is what makes the deadline mean "silent since", and a caller that arms twice
// without an intervening start must not restart it. 0 doubles as "not armed".
function unreachable(st, now) {
    return {
        streaming: false,
        unreachableSince: st.unreachableSince === 0 ? now : st.unreachableSince,
        lostFired: st.lostFired,
        lostAfterMs: st.lostAfterMs
    }
}
