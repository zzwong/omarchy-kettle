.pragma library

// Whether a remote host has been silent long enough to drop its pots.
//
// The clock is driven by lastSeen — set only where a line arrived, never by a
// spawn, because the channel's argv[0] is bash and starts even when ssh
// reaches nothing (#6). lostFired makes the drop an edge, not a level (#5).
// lastSeen 0 is "never heard from": no snapshot, so no pots to drop.

// st: {desiredRunning, idling, lastSeen, lostFired, lostAfterMs}
function lostGate(st, now) {
    var fire = st.desiredRunning
            && !st.idling
            && st.lastSeen > 0
            && !st.lostFired
            && (now - st.lastSeen) > st.lostAfterMs
    return {fire: fire, lostFired: st.lostFired || fire}
}

// The only release, so a host that recovers and dies again drops again.
function sawLine(st, now) {
    return {lastSeen: now, lostFired: false}
}
