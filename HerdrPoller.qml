import QtQuick
import Quickshell
import Quickshell.Io

// Polls `herdr api snapshot` — one call returns agents, panes, tabs,
// workspaces and focus state in ~2KB, so N agents cost exactly one process.
//
// Deliberately NOT event-driven: `herdr agent wait` takes one target and one
// state, so covering N agents across three interesting states would mean up to
// 3N supervised subprocesses, respawned on every transition, and it would
// still need a snapshot poll to discover agents appearing. 2s latency on a
// glanceable widget is not worth that.
QtObject {
  id: root

  property int activeInterval: 2000
  property int idleInterval: 15000

  // True while herdr has no server listening. Not an error state — most of the
  // time there simply is no session running.
  property bool serverDown: true
  property var agents: []
  property string focusedPaneId: ""

  signal snapshot(var agents, string focusedPaneId)
  signal serverLost()

  readonly property string home: Quickshell.env("HOME")

  function poll() {
    if (proc.running) return   // re-entrancy guard; a slow call must not stack
    proc.running = true
  }

  function handle(raw) {
    var text = String(raw || "").trim()
    if (text === "") return markDown()

    var doc
    try { doc = JSON.parse(text) } catch (e) { return markDown() }

    if (doc && doc.error) return markDown()

    var snap = doc && doc.result ? doc.result.snapshot : null
    if (!snap) return markDown()

    var list = Array.isArray(snap.agents) ? snap.agents : []
    var focused = String(snap.focused_pane_id || "")

    if (serverDown) {
      serverDown = false
      timer.interval = activeInterval
    }

    agents = list
    focusedPaneId = focused
    root.snapshot(list, focused)
  }

  function markDown() {
    if (!serverDown) {
      serverDown = true
      timer.interval = idleInterval
      agents = []
      focusedPaneId = ""
      root.serverLost()
    }
  }

  property Timer timer: Timer {
    interval: root.idleInterval
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  property Process proc: Process {
    command: ["herdr", "api", "snapshot"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handle(text)
    }
    onExited: function(code, status) {
      // A nonzero exit with no parseable stdout also means "no session".
      if (code !== 0 && root.agents.length === 0) root.markDown()
    }
  }

  // The socket appearing is the cheapest possible "herdr just started" signal,
  // so backoff costs nothing in responsiveness: watching the parent directory
  // because a FileView cannot observe a file that does not exist yet.
  property FileView socketWatch: FileView {
    path: root.home + "/.config/herdr"
    watchChanges: true
    printErrors: false
    onFileChanged: {
      if (root.serverDown) {
        root.timer.interval = root.activeInterval
        root.poll()
      }
    }
  }
}
