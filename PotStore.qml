import QtQuick
import Quickshell
import Quickshell.Io

// Unified pot model. Phase 1 has one source (herdr), but the shape is already
// source-agnostic so the shell hook can merge in later without a rewrite.
//
// Transitions are detected by comparing `state_change_seq` per pane, not by
// diffing objects: herdr increments that counter on every state change, so a
// working -> blocked -> working round-trip inside one poll window is still
// visible as "something happened" even though the status looks unchanged.
QtObject {
  id: root

  // Where the plugin's bin/ scripts live; bound by the Panel.
  property string pluginDir: ""

  // herdr-derived pots, re-derived from the snapshot every tick.
  property var herdrPots: []

  // Everything the bar and panel render: both sources, one list. Written as a
  // binding over both backing properties so either source updating refreshes it.
  readonly property var pots: {
    var out = herdrPots.slice()
    for (var k in hookPots) if (hookPots[k]) out.push(hookPots[k])
    for (var r in remotePots) if (remotePots[r]) out.push(remotePots[r])
    return out
  }

  // Pots that earn a place on the bar count. ready/burnt stay listed in the
  // panel until acknowledged but deliberately do not inflate the badge —
  // the count answers "how much is live", not "how much is unread".
  readonly property int liveCount: {
    var n = 0
    for (var i = 0; i < pots.length; i++) {
      var s = pots[i].state
      if (s === "simmering" || s === "needs-attention") n++
    }
    return n
  }

  readonly property int murkyCount: {
    var n = 0
    for (var i = 0; i < pots.length; i++) if (pots[i].state === "murky") n++
    return n
  }

  // Highest-severity state present, for tinting the bar glyph.
  readonly property string severity: {
    var order = ["needs-attention", "burnt", "ready", "simmering"]
    for (var o = 0; o < order.length; o++)
      for (var i = 0; i < pots.length; i++)
        if (pots[i].state === order[o]) return order[o]
    return "idle"
  }

  signal potChanged(var pot, string fromState)

  // NOTE ON `burnt`: no current source can produce it. herdr reports only
  // idle/working/blocked/done/unknown, and neither Claude Code nor Codex hooks
  // carry an exit status. It is reserved for shell-command pots, which report
  // exit codes and are not built yet. The rendering paths are kept because
  // they are correct and small — but nothing reaches them today, and the
  // README does not claim otherwise.
  //
  // herdr agent_status -> pot state. `idle` produces no pot at all: the agent
  // is ready for input and has already been seen, so there is nothing to say.
  // `unknown` is documented as NOT proving completion, so it can never become
  // ready and never notifies — it only ever surfaces as a footer count.
  function mapStatus(status) {
    switch (status) {
      case "working": return "simmering"
      case "blocked": return "needs-attention"
      case "done":    return "ready"
      case "unknown": return "murky"
      default:        return ""   // idle, or anything herdr adds later
    }
  }

  function reconcile(agents) {
    var now = Date.now()
    var prev = {}
    for (var i = 0; i < herdrPots.length; i++) prev[herdrPots[i].key] = herdrPots[i]

    var next = []
    for (var a = 0; a < agents.length; a++) {
      var ag = agents[a]
      if (!ag || !ag.pane_id) continue

      var state = mapStatus(String(ag.agent_status || ""))
      if (state === "") continue

      var key = "herdr:" + ag.pane_id
      var was = prev[key]
      var seq = Number(ag.state_change_seq)
      if (!isFinite(seq)) seq = -1

      // Keep the original `since` while the state holds, so the panel shows
      // time-in-state rather than time-since-first-seen.
      var changed = !was || was.state !== state || (seq >= 0 && was.seq !== seq)

      // When this pot last started working. Carried across reconciles so a
      // finished pot can report how long it actually ran — the one number that
      // cannot be reconstructed after the fact.
      var runStart = (was && was.runStart) ? was.runStart : now
      if (state === "simmering" && (!was || was.state !== "simmering")) runStart = now
      var ranMs = (was && was.ranMs) ? was.ranMs : 0
      // Measure from runStart regardless of the immediately preceding state: a
      // session that finishes from `needs-attention` (approved, then done) ran
      // just as long as one finishing from `simmering`, and reporting nothing
      // for it was an accident of the transition check.
      if ((state === "ready" || state === "burnt") && was && was.runStart)
        ranMs = now - was.runStart

      // pi keys its session logs by cwd, so a pi pot can name its model even
      // though herdr's snapshot cannot. A fresh prompt may have switched
      // models, so the cache entry is dropped on each transition into
      // simmering and re-read — one short process per state change, never
      // anything per poll.
      var model = ""
      if (String(ag.agent) === "pi") {
        var cwdFull = String(ag.cwd || "")
        if (state === "simmering" && (!was || was.state !== "simmering")
            && piModels[cwdFull] !== undefined) {
          var pmm = Object.assign({}, piModels); delete pmm[cwdFull]; piModels = pmm
        }
        if (piModels[cwdFull] === undefined) resolvePiModel(cwdFull)
        model = piModels[cwdFull] || ""
      }

      var pot = {
        key: key,
        source: "herdr",
        runStart: runStart,
        ranMs: ranMs,
        // A `herdr agent rename` name is the user's own word for the pane, so
        // it outranks the agent's self-set terminal title.
        label: String(ag.name || ag.terminal_title_stripped || ag.agent || "agent"),
        project: basename(String(ag.cwd || "")),
        state: state,
        since: (was && !changed) ? was.since : now,
        seq: seq,
        paneId: String(ag.pane_id),
        agentKind: String(ag.agent || ""),
        model: model
      }
      next.push(pot)

      if (!was || was.state !== state)
        root.potChanged(pot, was ? was.state : "")
    }

    herdrPots = next
  }

  // ---- pi model resolution -------------------------------------------------
  // cwd -> model slug. "" means "resolved, nothing found" and stops retries;
  // absence means "never asked". Local pots only: the session files this
  // reads live on this machine's disk.
  property var piModels: ({})
  property var piQueue: []
  property string piCwdInFlight: ""

  function resolvePiModel(cwd) {
    if (!cwd || pluginDir.length === 0) return
    if (piCwdInFlight === cwd || piQueue.indexOf(cwd) !== -1) return
    if (piModelProc.running) { piQueue.push(cwd); return }
    piCwdInFlight = cwd
    piModelProc.command = [pluginDir + "bin/kettle-pi-model", cwd]
    piModelProc.running = true
  }

  property Process piModelProc: Process {
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.piCwdInFlight.length === 0) return
        var pm = Object.assign({}, root.piModels)
        pm[root.piCwdInFlight] = String(text || "").trim().slice(0, 64)
        root.piModels = pm
      }
    }
    onExited: {
      root.piCwdInFlight = ""
      if (root.piQueue.length > 0) root.resolvePiModel(root.piQueue.shift())
    }
  }

  // ---- remote herdr source -------------------------------------------------
  // Same shape as local herdr, keyed by host so two machines cannot collide.
  // Kept apart from herdrPots because each host reconciles on its own channel.
  property var remotePots: ({})

  function reconcileRemote(host, agents) {
    var now = Date.now()
    var next = Object.assign({}, remotePots)
    var seen = {}

    for (var a = 0; a < agents.length; a++) {
      var ag = agents[a]
      var state = mapStatus(String(ag.agent_status || ""))
      if (state === "") continue

      var key = "rherdr:" + host + ":" + ag.pane_id
      seen[key] = true
      var was = next[key]
      var seq = Number(ag.state_change_seq)
      if (!isFinite(seq)) seq = -1
      var changed = !was || was.state !== state || (seq >= 0 && was.seq !== seq)

      var runStart = (was && was.runStart) ? was.runStart : now
      if (state === "simmering" && (!was || was.state !== "simmering")) runStart = now
      var ranMs = (was && was.ranMs) ? was.ranMs : 0
      if ((state === "ready" || state === "burnt") && was && was.runStart)
        ranMs = now - was.runStart

      var pot = {
        key: key,
        source: "rherdr",
        // Same hierarchy as local herdr pots: user-set name, then the agent's
        // live title, then the generic agent label. Both remote fields arrive
        // length-capped by the poller — cosmetic, remote-controlled input.
        label: String(ag.name || ag.terminal_title_stripped || "") || agentLabel(ag.agent),
        project: basename(String(ag.cwd || "")),
        state: state,
        since: (was && !changed) ? was.since : now,
        runStart: runStart,
        ranMs: ranMs,
        seq: seq,
        paneId: String(ag.pane_id),
        host: host,
        windowAddr: "",
        agentKind: String(ag.agent || ""),
        model: ""
      }
      next[key] = pot
      if (!was || was.state !== state) root.potChanged(pot, was ? was.state : "")
    }

    // Anything this host no longer reports is gone.
    for (var k in next)
      if (k.indexOf("rherdr:" + host + ":") === 0 && !seen[k]) delete next[k]

    remotePots = next
  }

  function dropRemoteHost(host) {
    var next = Object.assign({}, remotePots)
    for (var k in next) if (k.indexOf("rherdr:" + host + ":") === 0) delete next[k]
    remotePots = next
  }

  // ---- agent-hook source ---------------------------------------------------
  // Sessions outside herdr report their own lifecycle through the Kettle hook.
  // Kept in a separate map from the herdr-derived pots because the two sources
  // reconcile on completely different schedules: herdr pots are re-derived
  // from a snapshot every tick, hook pots persist until an event moves them.
  property var hookPots: ({})

  // `finished` becomes a pot only when the user was not looking. That is
  // herdr's `done` semantic reimplemented from the outside: Kettle knows the
  // focused Hyprland window, so it can tell "finished while you were away"
  // from "finished while you watched".
  function ingest(ev) {
    if (!ev || !ev.id) return
    var map = Object.assign({}, hookPots)
    // Host-scoped: two machines can hand out the same session id, and a
    // remote pot must never overwrite a local one.
    var key = "agent:" + (ev.host ? ev.host + ":" : "") + ev.id
    var was = map[key]
    var now = Date.now()

    var state = ""
    switch (ev.state) {
      case "register": map[key] = undefined; delete map[key]; hookPots = map; return
      case "working":  state = "simmering"; break
      case "blocked":  state = "needs-attention"; break
      case "finished":
        // Seen it already? Then there is nothing to report.
        if (ev.focused === true) {
          delete map[key]
          hookPots = map
          if (was) root.potChanged({ key: key, state: "" }, was.state)
          return
        }
        state = "ready"
        break
      case "gone":
        delete map[key]
        hookPots = map
        return
      default: return
    }

    var runStart = (was && was.runStart) ? was.runStart : now
    if (state === "simmering" && (!was || was.state !== "simmering")) runStart = now
    var ranMs = (was && was.ranMs) ? was.ranMs : 0
    if (state === "ready" && was && was.runStart)
      ranMs = now - was.runStart

    var pot = {
      key: key,
      source: "agent",
      runStart: runStart,
      ranMs: ranMs,
      label: root.agentLabel(ev.agent),
      project: basename(String(ev.cwd || "")),
      state: state,
      since: (was && was.state === state) ? was.since : now,
      seq: -1,
      paneId: "",
      windowAddr: canonAddr(ev.window),
      host: String(ev.host || ""),
      agentKind: String(ev.agent || ""),
      // Read from the session transcript by the hook: the payload itself
      // carries no model field.
      model: String(ev.model || "")
    }

    map[key] = pot
    hookPots = map

    if (!was || was.state !== state) root.potChanged(pot, was ? was.state : "")
  }

  // Display names for the agents we know; anything else keeps its own name
  // rather than being forced into a guess.
  function agentLabel(kind) {
    switch (String(kind || "")) {
      case "claude":     return "Claude Code"
      case "codex":      return "Codex"
      case "pi":         return "Pi"
      // Brands whose casing is not plain capitalisation.
      case "opencode":   return "opencode"
      case "maki":       return "maki"
      case "agy":        return "Antigravity"
      case "omp":        return "oh-my-pi"
      case "mastracode": return "Mastra Code"
      case "qodercli":   return "Qoder"
      case "":           return "agent"
      default:           return String(kind).charAt(0).toUpperCase() + String(kind).slice(1)
    }
  }

  // ---- model display names -------------------------------------------------
  // Agents already maintain model catalogs on disk — Codex's
  // models_cache.json (slug/display_name), pi's models-store.json (id/name) —
  // so slugs are looked up there and the heuristic below only handles what no
  // catalog knows. Watched files: no process is ever spawned for a name. Kept as one map per catalog because
  // catalogs disagree — pi and Codex both list gpt-5.6-luna and spell its
  // name differently — and the agent that emitted the pot should win.
  property var codexNames: ({})
  property var piNames: ({})

  function catalogAdd(map, id, name) {
    if (typeof id === "string" && typeof name === "string" && id && name)
      map[id.toLowerCase()] = String(name).slice(0, 48)
  }

  function rebuildModelNames() {
    var cmap = {}
    try {
      var cx = JSON.parse(codexModelsFile.text())
      var ms = Array.isArray(cx.models) ? cx.models : []
      for (var i = 0; i < ms.length; i++) catalogAdd(cmap, ms[i].slug, ms[i].display_name)
    } catch (e) { /* absent or malformed: the heuristic still covers it */ }
    codexNames = cmap

    var pmap = {}
    try {
      var store = JSON.parse(piModelsFile.text())
      for (var prov in store) {
        var pm = (store[prov] && Array.isArray(store[prov].models)) ? store[prov].models : []
        for (var j = 0; j < pm.length; j++) catalogAdd(pmap, pm[j].id, pm[j].name)
      }
    } catch (e) {}
    piNames = pmap
  }

  property FileView codexModelsFile: FileView {
    path: (Quickshell.env("CODEX_HOME") || Quickshell.env("HOME") + "/.codex") + "/models_cache.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.rebuildModelNames()
    // `text()` is stale inside the change signal itself; route through reload
    // so onLoaded always parses fresh content.
    onFileChanged: reload()
  }
  property FileView piModelsFile: FileView {
    path: Quickshell.env("HOME") + "/.pi/agent/models-store.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.rebuildModelNames()
    onFileChanged: reload()
  }

  // Fallback for slugs no catalog knows. "opus-5" -> "Opus 5", "haiku-4-5" ->
  // "Haiku 4.5", "gpt-5.6-luna" -> "GPT-5.6-Luna". Version fragments join with
  // a dot; everything else is a word. Checked against codex-cli's cache: every
  // current display name is the slug hyphen-joined and capitalized, so GPT
  // models keep their hyphens where Anthropic's names are words.
  function prettyModel(m, kind) {
    var raw = String(m || "")
    if (!raw) return ""
    var key = raw.toLowerCase()
    var own = (kind === "codex") ? codexNames : (kind === "pi") ? piNames : null
    var hit = (own && own[key]) || codexNames[key] || piNames[key]
    if (hit) return hit
    var parts = raw.split("-")
    var out = []
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i]
      if (!p) continue
      if (/^\d+$/.test(p) && out.length > 0 && /\d$/.test(out[out.length - 1])) {
        // consecutive numbers are one version, not two words
        out[out.length - 1] += "." + p
      } else if (/^(gpt|o\d)$/i.test(p)) {
        out.push(p.toUpperCase())
      } else if (/^\d/.test(p)) {
        out.push(p)
      } else {
        out.push(p.charAt(0).toUpperCase() + p.slice(1))
      }
    }
    return /^gpt/i.test(raw) ? out.join("-") : out.join(" ")
  }

  function hookList() {
    var out = []
    for (var k in hookPots) if (hookPots[k]) out.push(hookPots[k])
    return out
  }

  // Looking at the window IS the acknowledgement — the same signal herdr uses
  // internally, reimplemented for sessions it does not manage. Only terminal
  // pots clear this way: a blocked agent is still genuinely waiting on an
  // answer, so glancing at it must not silence the reminder.
  function seenWindow(addr) {
    if (!addr) return
    var map = Object.assign({}, hookPots)
    var changed = false
    for (var k in map) {
      var pot = map[k]
      if (!pot || canonAddr(pot.windowAddr) !== canonAddr(addr)) continue
      if (pot.state === "ready" || pot.state === "burnt") {
        delete map[k]
        changed = true
      }
    }
    if (changed) hookPots = map
  }

  function dropHookPot(key) {
    var map = Object.assign({}, hookPots)
    delete map[key]
    hookPots = map
  }

  // Only herdr pots vanish when herdr does; hook-sourced sessions are
  // independent of it and must survive a herdr server restart.
  function clear() {
    if (herdrPots.length > 0) herdrPots = []
  }

  // Hyprland addresses arrive from three places — hyprctl (always 0x-prefixed),
  // Quickshell's toplevel model, and our own relay — and they were compared as
  // raw strings. One unprefixed source would silently break focus-clearing,
  // so every address is canonicalised here and nowhere else.
  function canonAddr(a) {
    var s = String(a || "").trim().toLowerCase()
    if (s.length === 0) return ""
    return s.indexOf("0x") === 0 ? s : "0x" + s
  }

  function basename(p) {
    if (!p) return ""
    var parts = p.replace(/\/+$/, "").split("/")
    return parts[parts.length - 1] || p
  }

  // A pot that is still cooking gets a live m:ss clock — the ticking IS the
  // signal that work is ongoing. A finished pot must not tick: a running
  // counter on something that already stopped reads as "still going".
  // Terminal states get a coarse "how long ago", which changes at most once a
  // minute and never looks like a stopwatch.
  readonly property var liveStates: ["simmering", "needs-attention"]

  function isLive(state) {
    return liveStates.indexOf(state) !== -1
  }

  function label(pot) {
    return isLive(pot.state) ? elapsed(pot.since) : sinceWord(pot.since)
  }

  function elapsed(since) {
    var s = Math.max(0, Math.floor((Date.now() - since) / 1000))
    var m = Math.floor(s / 60)
    var r = s % 60
    return m + ":" + (r < 10 ? "0" : "") + r
  }

  // Duration a pot actually ran, for the subtitle of a finished pot.
  function ranWord(pot) {
    if (!pot.ranMs || pot.ranMs < 1000) return ""
    var s = Math.floor(pot.ranMs / 1000)
    if (s < 60) return "ran " + s + "s"
    var m = Math.floor(s / 60)
    var r = s % 60
    if (m < 60) return "ran " + m + ":" + (r < 10 ? "0" : "") + r
    return "ran " + Math.floor(m / 60) + "h" + (m % 60) + "m"
  }

  function sinceWord(since) {
    var s = Math.max(0, Math.floor((Date.now() - since) / 1000))
    if (s < 60) return "just now"
    var m = Math.floor(s / 60)
    if (m < 60) return m + "m ago"
    var h = Math.floor(m / 60)
    return h + "h ago"
  }

  // Whether anything on screen actually needs a per-second repaint.
  readonly property bool hasLive: {
    for (var i = 0; i < pots.length; i++) if (isLive(pots[i].state)) return true
    return false
  }
}
