import QtQuick
import Quickshell

// Notification policy. The bar always shows true state; notifications are the
// escalation, so every rule here is about staying quiet, not about informing.
//
// Fires only on transitions INTO needs-attention / ready / burnt. Pots
// appearing, idle churn and removals are bar-only.
QtObject {
  id: root

  property bool enabled: true
  property int cooldownMs: 60000     // per pot, per state
  property int settleMs: 3000        // coalescing window

  // paneId of the currently focused herdr pane, so we can stay silent about
  // something the user is demonstrably looking at.
  property string focusedPaneId: ""
  // Hook and remote pots carry a window address instead of a pane id.
  property string focusedWindow: ""

  property var lastFired: ({})       // key+state -> timestamp
  property var pending: []
  // Resolve delayed candidates against the store at dispatch time. Object
  // snapshots can outlive an acknowledgment, a removed session or a new turn.
  property var currentPots: []

  onEnabledChanged: {
    if (!enabled) {
      pending = []
      if (settle) settle.stop()
    }
  }

  // Injected by Panel.qml so the glyph set lives in exactly one place.
  property string glyphAttention: ""
  property string glyphReady: ""
  property string glyphBurnt: ""

  function glyphFor(state) {
    if (state === "needs-attention") return glyphAttention
    if (state === "burnt") return glyphBurnt
    return glyphReady
  }

  function isFocused(pot) {
    return (pot.paneId && pot.paneId === focusedPaneId)
      || (pot.windowAddr && focusedWindow && pot.windowAddr === focusedWindow)
  }

  function consider(pot, fromState) {
    if (!pot) return

    // A newer transition replaces this key even if it is no longer eligible
    // to notify. In particular, never count blocked and ready as two pots.
    pending = pending.filter(function(item) { return item.key !== pot.key })
    if (!enabled) return

    var s = pot.state
    if (s !== "needs-attention" && s !== "ready" && s !== "burnt") return

    // Never announce the first sighting of an already-blocked agent on
    // startup — only genuine transitions during this session.
    if (fromState === "") return

    // You are looking straight at it — by pane (herdr) or by window (hook,
    // remote). Checking only the pane silently exempted every non-herdr pot.
    if (isFocused(pot)) return

    var stamp = pot.key + ":" + s
    var now = Date.now()
    if (lastFired[stamp] && (now - lastFired[stamp]) < cooldownMs) return

    var next = Object.assign({}, lastFired)
    next[stamp] = now
    lastFired = next

    pending.push(pot)
    settle.restart()
  }

  function flush() {
    var candidates = pending
    pending = []
    if (!enabled) return

    var items = []
    for (var c = 0; c < candidates.length; c++) {
      var candidate = candidates[c]
      for (var p = 0; p < currentPots.length; p++) {
        var current = currentPots[p]
        if (current.key !== candidate.key) continue
        // Tokens survive unchanged snapshots but not state changes, observed
        // herdr revisions, or removal/recreation, even in the same millisecond.
        if (current.notificationToken && current.notificationToken === candidate.notificationToken
            && current.state === candidate.state && !isFocused(current))
          items.push(current)
        break
      }
    }
    if (items.length === 0) return

    if (items.length === 1) return send(items[0])

    // More than one inside the settle window: one summary instead of a stack.
    var names = []
    for (var i = 0; i < items.length; i++) {
      var n = items[i].project || items[i].label
      if (names.indexOf(n) === -1) names.push(n)
    }
    var worst = items[0]
    for (var j = 0; j < items.length; j++)
      if (items[j].state === "needs-attention") { worst = items[j]; break }

    Quickshell.execDetached([
      "omarchy-notification-send",
      "-g", glyphFor(worst.state),
      "-u", worst.state === "needs-attention" ? "critical" : "normal",
      items.length + " pots need you",
      names.join(", "),
      // Several pots, so no single place to jump; the panel lists them all.
      // --exec is last because omarchy-notification-send only recognises it
      // after the positionals, so an untrusted headline can never become it.
      "--exec", "omarchy-shell", "kettle", "open"
    ])
  }

  function send(pot) {
    var headline, body
    switch (pot.state) {
      case "needs-attention":
        headline = pot.label + " needs approval"
        body = pot.project
        break
      case "burnt":
        headline = pot.label + " failed"
        body = pot.project
        break
      default:
        headline = pot.label + " is ready"
        body = pot.project
    }

    Quickshell.execDetached([
      "omarchy-notification-send",
      "-g", glyphFor(pot.state),
      "-u", pot.state === "needs-attention" ? "critical" : "normal",
      headline,
      body,
      // Clicking the toast jumps to the pot exactly as a row click would: the
      // daemon runs this argv as-is and Panel resolves the key at click time.
      "--exec", "omarchy-shell", "kettle", "jump", pot.key
    ])
  }

  property Timer settle: Timer {
    interval: root.settleMs
    repeat: false
    onTriggered: root.flush()
  }
}
