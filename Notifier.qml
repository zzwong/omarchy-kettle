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

  // Injected by Panel.qml so the glyph set lives in exactly one place.
  property string glyphAttention: ""
  property string glyphReady: ""
  property string glyphBurnt: ""

  function glyphFor(state) {
    if (state === "needs-attention") return glyphAttention
    if (state === "burnt") return glyphBurnt
    return glyphReady
  }

  function consider(pot, fromState) {
    if (!enabled) return
    if (!pot) return

    var s = pot.state
    if (s !== "needs-attention" && s !== "ready" && s !== "burnt") return

    // Never announce the first sighting of an already-blocked agent on
    // startup — only genuine transitions during this session.
    if (fromState === "") return

    // You are looking straight at it — by pane (herdr) or by window (hook,
    // remote). Checking only the pane silently exempted every non-herdr pot.
    if (pot.paneId && pot.paneId === focusedPaneId) return
    if (pot.windowAddr && focusedWindow && pot.windowAddr === focusedWindow) return

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
    var items = pending
    pending = []
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
      names.join(", ")
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
      body
    ])
  }

  property Timer settle: Timer {
    interval: root.settleMs
    repeat: false
    onTriggered: root.flush()
  }
}
