import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// Receives agent events from remote hosts over an ssh reverse forward.
//
// The listener is a unix socket owned by the shell itself rather than an
// external daemon. ssh can forward a remote TCP port straight into a local
// unix socket (`ssh -R 127.0.0.1:PORT:/path/to.sock`), which means no daemon,
// no systemd unit, and delivery is a direct call instead of a subprocess.
//
// Note the asymmetry that makes this work: forwarding a *remote* unix socket
// fails, because sshd creates it root-owned and mode 600. Remote-TCP to
// local-unix has no such problem.
//
// Wire format, one connection per event, one line:
//   v1 <token> <base64-json>\n
// The reply is one line: ok | need-nonce | no-window | denied
QtObject {
  id: root

  property QtObject store: null
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ("/run/user/1000")
  readonly property string sockPath: runtimeDir + "/kettle/kettle.sock"
  readonly property string tokenDir: Quickshell.env("HOME") + "/.config/kettle/tokens"

  // token -> host. The FILENAME is the origin host; a payload never gets to
  // say where it came from.
  property var tokens: ({})
  property bool tokensLoaded: false

  // sid -> { addr, host }. Survives as long as the shell does; a reload costs
  // one extra nonce round per session, which is cheap.
  property var resolved: ({})

  // token -> [timestamps], trimmed to the last second.
  property var rate: ({})

  readonly property int maxLine: 16384
  readonly property int maxPerSecond: 20
  readonly property int resolveTimeoutMs: 1500

  signal rejected(string reason)

  // Token filenames are the host registry — the same list the relay
  // authenticates against drives which hosts we stream herdr from.
  readonly property var hostList: {
    var out = []
    for (var t in tokens) if (tokens[t]) out.push(tokens[t])
    out.sort()
    return out
  }

  // ---- tokens -------------------------------------------------------------
  // Read lazily and re-read on a miss, which sidesteps directory-watch
  // semantics entirely: a newly added host authenticates on its first event.
  function loadTokens(done) {
    tokenLoader.callback = done || null
    tokenLoader.running = true
  }

  function hostFor(token, retry) {
    if (tokens[token]) return tokens[token]
    if (retry !== false && tokensLoaded) {
      // Miss against a stale map: reload once, the caller retries.
      loadTokens(null)
    }
    return ""
  }

  // Constant-time-ish compare. Timing attacks through ssh jitter are not a
  // practical threat, but the loop is five lines and the habit is correct.
  function tokenMatches(a, b) {
    if (a.length !== b.length) return false
    var diff = 0
    for (var i = 0; i < a.length; i++) diff |= (a.charCodeAt(i) ^ b.charCodeAt(i))
    return diff === 0
  }

  function lookupHost(token) {
    for (var t in tokens) if (tokenMatches(t, token)) return tokens[t]
    return ""
  }

  // ---- rate limiting ------------------------------------------------------
  function overRate(host) {
    var now = Date.now()
    var arr = (rate[host] || []).filter(function(t) { return now - t < 1000 })
    arr.push(now)
    var next = Object.assign({}, rate)
    next[host] = arr
    rate = next
    return arr.length > maxPerSecond
  }

  // ---- window resolution --------------------------------------------------
  // No hyprctl, no polling: Hyprland.toplevels is a reactive model, so the
  // nonce either is already there or arrives as a titleChanged.
  function findByTitle(title) {
    var list = Hyprland.toplevels
    if (!list) return ""
    for (var i = 0; i < list.values.length; i++) {
      var tl = list.values[i]
      if (tl && String(tl.title) === title) return String(tl.address)
    }
    return ""
  }

  function addressLive(addr) {
    var list = Hyprland.toplevels
    if (!list || !addr) return false
    for (var i = 0; i < list.values.length; i++)
      if (list.values[i] && String(list.values[i].address) === addr) return true
    return false
  }

  function activeAddress() {
    var tl = Hyprland.activeToplevel
    return tl ? String(tl.address) : ""
  }

  // ---- ingestion ----------------------------------------------------------
  readonly property var validStates: ["register", "working", "blocked", "finished", "gone"]

  function sanitize(raw, host) {
    if (!raw || typeof raw !== "object") return null
    var id = String(raw.id || "")
    if (!/^[A-Za-z0-9_.-]{1,64}$/.test(id)) return null
    var state = String(raw.state || "")
    if (validStates.indexOf(state) === -1) return null

    // Rebuilt from scratch, never passed through: host, window and focused are
    // ours to decide, and anything else the sender invented is discarded.
    return {
      source: "agent",
      agent: String(raw.agent || "agent").slice(0, 32),
      id: id,
      state: state,
      cwd: String(raw.cwd || "").slice(0, 512),
      message: String(raw.message || "").slice(0, 160),
      // Cosmetic and self-reported, so it is bounded and never trusted for
      // anything that matters — but stripping it would blank the model on
      // every remote pot.
      model: String(raw.model || "").slice(0, 40).replace(/[^A-Za-z0-9._-]/g, ""),
      host: host,
      window: "",
      focused: false
    }
  }

  function handleLine(line, reply) {
    if (line.length > maxLine) { root.rejected("oversize"); return reply("denied") }

    var parts = line.split(" ")
    if (parts.length !== 3 || parts[0] !== "v1") { root.rejected("malformed"); return reply("denied") }

    var host = lookupHost(parts[1])
    if (!host) {
      // Could be a host added since we last read the directory.
      loadTokens(function() {
        var h = lookupHost(parts[1])
        if (!h) { root.rejected("bad token"); return reply("denied") }
        accept(h, parts[2], reply)
      })
      return
    }
    accept(host, parts[2], reply)
  }

  function accept(host, b64, reply) {
    if (overRate(host)) { root.rejected("rate limit: " + host); return reply("denied") }

    var raw
    try { raw = JSON.parse(Qt.atob(b64)) } catch (e) { root.rejected("bad payload"); return reply("denied") }

    var ev = sanitize(raw, host)
    if (!ev) { root.rejected("invalid fields"); return reply("denied") }

    var key = host + ":" + ev.id

    if (ev.state === "gone") {
      var gmap = Object.assign({}, resolved); delete gmap[key]; resolved = gmap
      deliver(ev)
      return reply("ok")
    }

    var cached = resolved[key]
    if (cached && addressLive(cached)) {
      ev.window = cached
      ev.focused = (ev.state === "finished") && (activeAddress() === cached)
      deliver(ev)
      return reply("ok")
    }

    // Cache miss, or the window went away (tmux reattached elsewhere). Ask the
    // remote to re-announce itself, and try to catch the nonce it already sent.
    var nonce = "kettle:" + ev.id
    var addr = findByTitle(nonce)
    if (addr) {
      var rmap = Object.assign({}, resolved); rmap[key] = addr; resolved = rmap
      ev.window = addr
      ev.focused = (ev.state === "finished") && (activeAddress() === addr)
      deliver(ev)
      return reply("ok")
    }

    // Not there yet. Deliver without a jump target so the pot still appears,
    // and wait briefly for the title to land.
    deliver(ev)
    waitForNonce(key, nonce, reply, cached ? "need-nonce" : "no-window")
  }

  function deliver(ev) {
    if (store) store.ingest(ev)
  }

  // Subscribe to the model rather than polling it: titles arrive as signals.
  function waitForNonce(key, nonce, reply, fallbackAck) {
    var comp = Qt.createQmlObject(
      'import QtQuick; Timer { interval: 60; repeat: true }', root)
    var elapsed = 0
    comp.triggered.connect(function() {
      elapsed += comp.interval
      var addr = root.findByTitle(nonce)
      if (addr) {
        var rmap = Object.assign({}, root.resolved); rmap[key] = addr; root.resolved = rmap
        comp.stop(); comp.destroy()
        reply("ok")
        return
      }
      if (elapsed >= root.resolveTimeoutMs) {
        comp.stop(); comp.destroy()
        reply(fallbackAck)
      }
    })
    comp.start()
  }

  // ---- plumbing -----------------------------------------------------------
  property Process tokenLoader: Process {
    property var callback: null
    command: ["bash", "-c",
      // shopt -s dotglob: a token file named .something would otherwise be
      // silently invisible, with no error to explain the denial.
      'shopt -s dotglob nullglob; d="$HOME/.config/kettle/tokens"; [ -d "$d" ] || exit 0; ' +
      'for f in "$d"/*; do [ -f "$f" ] || continue; printf "%s\\t%s\\n" "$(basename "$f")" "$(cat "$f")"; done']
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var map = {}
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var p = lines[i].split("\t")
          if (p.length === 2 && p[1].length > 0) map[p[1]] = p[0]
        }
        root.tokens = map
        root.tokensLoaded = true
        if (tokenLoader.callback) { var cb = tokenLoader.callback; tokenLoader.callback = null; cb() }
      }
    }
  }

  // Ensure the runtime dir exists and is private before binding. Socket file
  // mode is umask-dependent and unix connect needs write permission, so the
  // directory is what actually enforces same-uid-only access.
  property Process dirMaker: Process {
    running: true
    command: ["bash", "-c", 'mkdir -p "$(dirname "' + root.sockPath + '")" && chmod 700 "$(dirname "' + root.sockPath + '")"']
    onExited: server.active = true
  }

  property SocketServer server: SocketServer {
    path: root.sockPath
    active: false

    handler: Socket {
      id: conn

      // A sender that never completes a line must not pin memory: there is no
      // buffer cap on SplitParser, so bound the connection by time instead.
      property Timer idle: Timer {
        interval: 3000
        running: true
        onTriggered: conn.connected = false
      }

      parser: SplitParser {
        onRead: function(line) {
          conn.idle.restart()
          root.handleLine(String(line).trim(), function(ack) {
            conn.write(ack + "\n")
            conn.flush()
            conn.connected = false
          })
        }
      }
    }
  }

  Component.onCompleted: loadTokens(null)

  onRejected: function(reason) { console.warn("kettle relay rejected:", reason) }
}
