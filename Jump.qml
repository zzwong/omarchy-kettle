import QtQuick
import Quickshell
import Quickshell.Io

// Shared "jump to a pot's window" logic — the two-step herdr focus+raise,
// the hook path's direct window focus, and the rherdr ssh focus. Extracted
// from Panel.qml so the Stage overlay can call the identical mechanism
// without a second copy (and, more importantly, without a second `raiser`
// Process: two open surfaces racing to raise the same herdr window would be
// a duplicate-spawn hazard, not just duplicated code).
//
// Callers own their own surface's close/dismiss — this component never
// closes anything, so a bar-panel jump and an overlay jump can each decide
// their own before/after ordering.
QtObject {
  id: root

  // PotStore instance: only isLive()/dropHookPot() are used.
  required property var store
  // Relay instance: only herdrPathFor() is used.
  required property var relay
  required property string pluginDir
  required property string herdrWindow
  // Empty falls back to the host name, which matches herdr's default remote
  // window title of "{hostname}: {workspace}".
  property string remoteWindow: ""

  // Clicking a pot is the acknowledgement: focusing the tab flips herdr from
  // `done` to `idle`, and CLI reads never mark a tab seen — so the next poll
  // drops the pot with no widget-side bookkeeping at all.
  //
  // Two steps, because `herdr agent focus` switches herdr's internal tab but
  // does NOT raise the OS window. Without the second step the jump silently
  // does nothing visible when herdr is on another workspace.
  function jump(pot) {
    if (!pot) return

    // Hook-sourced sessions carry their own window address, resolved once at
    // SessionStart via an OSC 2 title nonce. No herdr involved, and no
    // resolver subprocess needed.
    if (pot.source === "agent") {
      if (pot.windowAddr) focusWindow(pot.windowAddr)
      // Only a finished pot is dismissed by looking at it. A session that is
      // still working stays on the bar after you jump to it — clearing it
      // would hide live work behind a single click.
      if (!root.store.isLive(pot.state)) root.store.dropHookPot(pot.key)
      return
    }

    if (pot.source === "rherdr") {
      // Rides the user's existing ControlMaster (~48ms). ControlMaster=no so
      // we can never become the master a reload would then kill.
      Quickshell.execDetached([
        "ssh", "-o", "BatchMode=yes", "-o", "ControlMaster=no",
        "-o", "ControlPath=" + Quickshell.env("HOME") + "/.ssh/cm-%r@%h:%p",
        // Absolute path, resolved at install: a non-interactive ssh gets no
        // login shell, so a bare `herdr` fails with "command not found" —
        // silently, because execDetached discards output.
        // paneId is regex-validated on ingest and herdrPath on load, so this
        // interpolation is safe — but it runs on the remote, not here.
        "--", pot.host,
        (root.relay.herdrPathFor(pot.host) || "herdr") + " agent focus " + pot.paneId
      ])
      // The window to raise is the local terminal holding the ssh session.
      root.raise(root.remoteWindow || pot.host)
      return
    }

    if (!pot.paneId) return
    Quickshell.execDetached(["herdr", "agent", "focus", pot.paneId])
    root.raise(root.herdrWindow)
  }

  function raise(match) {
    raiser.running = false
    raiser.command = [root.pluginDir + "bin/kettle-herdr-window", match]
    raiser.running = true
  }

  function focusWindow(addr) {
    // Hyprland's dispatch API is Lua now: the old
    // `hyprctl dispatch focuswindow address:0x…` form is a parse error, and
    // hl.dispatch() wants a dispatcher object rather than a string.
    Quickshell.execDetached([
      "hyprctl", "dispatch",
      "hl.dsp.focus({ window = \"address:" + addr + "\" })"
    ])
  }

  property Process raiser: Process {
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var addr = String(text || "").trim()
        if (addr.length > 0) return root.focusWindow(addr)
        // The one failure the user can fix themselves (set herdrWindow), so
        // it must not fail silently.
        console.warn("kettle: cannot locate herdr's window — herdr's internal "
          + "tab switched, but nothing was raised. On a single-process "
          + "terminal set \"herdrWindow\" (local) or \"remoteWindow\" (the "
          + "terminal holding your ssh session) to a title substring "
          + "(see README).")
      }
    }
  }
}
