import QtQuick
import Quickshell.Io
import "Navigation.js" as Navigation

QtObject {
  id: root
  property string pluginDir: ""
  property var store: null
  property var pending: null
  property var snapshot: null
  property int serial: 0
  property bool draining: false
  readonly property bool busy: pending !== null || draining || jumper.running
  property string outcome: ""
  property string output: ""
  property bool oversized: false
  signal failed(string message)
  signal completed(string resolution)

  function fail(code) {
    outcome = Navigation.message(code)
    failed(outcome)
  }
  function start(pot) {
    if (!pot) return
    if (busy) {
      if (!pending || !Navigation.same(pending.target, pot.navigation)) fail("busy")
      return
    }
    if (!pot.navigation || pot.navigationError) { fail(pot.navigationError || "invalid-target"); return }
    var req = Navigation.request("jump_" + (++serial), pot.navigation)
    if (!req) { fail("invalid-target"); return }
    var arg = JSON.stringify(req)
    if (Navigation.bytes(arg) > 2048) { fail("invalid-target"); return }
    snapshot = pot
    pending = req
    output = ""
    oversized = false
    outcome = ""
    jumper.command = [pluginDir.replace(/\/?$/, "/") + "bin/" + Navigation.descriptor(req.target.app).helper, arg]
    deadline.restart()
    jumper.running = true
  }
  function cancel(code) {
    if (!busy) return
    // Invalidate before stopping: a late exit cannot acknowledge anything.
    pending = null
    snapshot = null
    deadline.stop()
    draining = jumper.running
    if (jumper.running) jumper.signal(15)
    reap.restart()
    fail(code || "cancelled")
  }
  function finish(code) {
    if (!pending) return
    var receipt = !oversized && Navigation.result(output.trim(), code, pending)
    var pot = snapshot
    pending = null
    snapshot = null
    deadline.stop()
    if (!receipt || !receipt.ok) { fail(receipt ? receipt.code : "transport-failed"); return }
    // Helpers finish verified focus before returning their receipt. Lifecycle
    // revision and object identity protect repeated and removed/recreated pots.
    if (store) store.acknowledgeHookPot(pot)
    outcome = ""
    completed(receipt.resolution)
  }
  Component.onDestruction: {
    pending = null; snapshot = null
    if (jumper.running) jumper.signal(15)
  }
  property Connections lifecycle: Connections {
    target: root.store
    function onHookPotsChanged() {
      if (root.pending && root.snapshot && !root.store.hookPots[root.snapshot.key])
        root.cancel("cancelled")
    }
  }
  property Timer reap: Timer {
    interval: 200
    onTriggered: { if (root.draining) jumper.running = false }
  }
  property Timer deadline: Timer {
    interval: 9800
    onTriggered: root.cancel("timeout")
  }
  property Process jumper: Process {
    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: {
        if (Navigation.bytes(text) > 4096) {
          root.oversized = true
          root.cancel("transport-failed")
        } else root.output = text
      }
    }
    // Child stderr is discarded: transport errors may contain private URLs.
    onExited: function(code, status) {
      root.finish(status === 0 ? code : -1)
      root.draining = false
      reap.stop()
    }
  }
}
