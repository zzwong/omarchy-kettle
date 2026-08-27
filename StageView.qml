import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import QtQuick.Effects
import QtQuick.Shapes
import qs.Commons
import "PreviewSource.js" as PreviewSource

// Kettle Stage — Mission Control for pots: every agent session as a live
// preview slab, click or Enter to jump. This is the `overlay` entry point
// (see manifest.json); Panel.qml is the separate `bar-widget` entry point.
//
// The skewed-slice carousel and the picker grid (PotSlab below, the
// carousel and grid Loaders, the open/close/keyboard/zoom contract) are
// vendored from omarchy-stage's Stage.qml at commit
// 38ae63f0447026285d36c9426c7e93dffc84b665 — WsSlab, the picker carousel,
// the picker grid, kbdPriority, the deliberate-hover MouseArea, and the
// Up/Down zoom between the two views are near-verbatim ports with the
// Hyprland-workspace/monitor mapping stripped and a pot's resolved preview
// (screencopy | text | card, see PreviewSource.js) dropped in where Stage
// drew a repeater of workspace toplevels. Stage's "cards" style and its
// pane-mode zoom (a third level inside the carousel's expanded preview,
// for picking a window within a workspace) are Stage-only and were not
// ported — pots have no per-window layout for pane mode to zoom into, and
// the plan defers acting on a pot from the overlay. Drift from Stage is
// accepted; this header is the provenance note docs/plan-stage-view.md
// asks for.
//
// Pot state (hook, local herdr, and remote herdr pots alike) comes from
// KettleService.qml, injected as `service` by the shell's panel loader
// (shell.qml: kinds panel/overlay/menu get `item.service =
// shell.serviceFor(...)` on load) — one PotStore shared with Panel.qml
// instead of this file standing up its own. Before that service kind
// existed, `IpcHandler{target:"kettle"}` and Relay's SocketServer were
// single-owner and Panel.qml already held both, so this view's own PotStore
// could only ever see local herdr pots; that gap is what KettleService.qml
// closes. What stays local to this file is everything about how the overlay
// *reads* a pot once it exists — batched herdr text reads, seq-driven
// re-reads, throttled remote reads — none of which is ingestion.
Item {
  id: root

  // Injected by the shell host's overlay Loader (shell.qml
  // computePanelEntries/panelLoaders) once this component is created —
  // never set by anything in this repo. `opened`, `open()`, `close()` below
  // are the contract that loader drives. `service` is the same injection
  // mechanism (`if ("service" in item) item.service = shell.serviceFor(...)`)
  // pointed at KettleService.qml's shared instance — see that file's header.
  property var shell: null
  property var manifest: null
  property var service: null

  readonly property string pluginDir:
    Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")

  property bool opened: false
  property int selectedIndex: -1

  // After a navigation keypress the keyboard owns selection; hover only
  // re-takes it once the mouse moves a deliberate distance (see PotSlab's
  // slabMouse — vendored from Stage's WsSlab, same bug class: an onEntered
  // hover-select would otherwise snap selection back right after the
  // keyboard moved it away).
  property bool kbdPriority: false

  // "carousel" is the zoomed-in slice view; "grid" lays every pot out at
  // once. Up zooms out, Down zooms back in (or falls back out of a grid
  // edge) — the same two-view zoom as Stage's "auto" view, minus the
  // settings surface that lets Stage lock to one view (plan defers
  // settings, so kettle always behaves as "auto").
  property string viewMode: "carousel"

  // Grid-view layout, shared by the grid Loader below and the key handler's
  // spatial navigation: the column count that maximizes card size. The
  // search itself is PreviewSource.gridFit, ported from Stage's `gridFit`
  // property (Stage.qml:62-73) into a pure function so it runs through the
  // qs test harness the same way resolve()/seqRereads() do, instead of only
  // being checkable by eye.
  readonly property real gridGap: Style.space(18)
  readonly property var gridFit: PreviewSource.gridFit(
    root.slotCount, panel.width * 0.88, panel.height * 0.74,
    root.previewAspect, root.gridGap)
  readonly property int gridCols: Math.max(1, gridFit.cols)

  // Floor for a screencopy preview's scale, the pixel counterpart of the text
  // preview's optical zoom. Below roughly half native a terminal capture stops
  // being readable and starts being texture, so slabs smaller than that crop
  // instead of shrinking further.
  readonly property real minPreviewScale: 0.5

  // Shear slope shared by every parallelogram (28px over a 519px reference
  // height), so skewed edges stay parallel at any slab size. Copied from
  // Stage verbatim — deliberately not re-derived, so the visual language
  // matches.
  readonly property real skewSlope: 28 / 519

  // Theme tokens: reuses the image-picker surface, same as Stage, so the
  // overlay matches the theme switcher rather than inventing a third look.
  readonly property color background: Color.menu.background
  readonly property color pickerText: Color.imagePicker.text
  readonly property color pickerSelectedBorder: Color.imagePicker.selectedBorder
  readonly property color pickerUnselectedBorder: Color.imagePicker.unselectedBorder

  // Kettle has no monitor to preview (a pot isn't tied to screen geometry
  // the way a workspace is), so the carousel locks to a fixed content aspect
  // rather than Stage's `monAspect`. 16:9 is the obvious default for
  // terminal/text panes and video previews alike.
  readonly property real previewAspect: 16 / 9

  // ---- glyph-first state rules ---------------------------------------
  // Mirrors Panel.qml's severityColor()/stateGlyph()/glyph table (see
  // AGENTS.md's file map) — duplicated rather than shared because those are
  // private to that file today, not exported. Hoisting them into PotStore is
  // the natural follow-up (docs/plan-stage-view.md's chip section already
  // names this) but is a Panel.qml change, out of scope for the viewer.
  readonly property string glyphSimmering: "󰅶"
  readonly property string glyphAttention: "󰗖"
  readonly property string glyphReady:     "󰗠"
  readonly property string glyphBurnt:     "󰀦"
  readonly property string glyphMurky:     "󰮎"

  function severityColor(state) {
    switch (state) {
      case "needs-attention": return Color.urgent
      case "burnt":           return Color.urgent
      case "ready":           return Color.accent
      case "murky":           return Color.muted
      default:                return root.pickerText
    }
  }

  function stateGlyph(state) {
    switch (state) {
      case "needs-attention": return root.glyphAttention
      case "ready":           return root.glyphReady
      case "burnt":           return root.glyphBurnt
      case "murky":           return root.glyphMurky
      default:                return root.glyphSimmering
    }
  }

  // ---- pot data ---------------------------------------------------------
  // Shared with Panel.qml via KettleService.qml (see file header). Never fed
  // anything — a stable, correctly-shaped stand-in for the shared store
  // during the brief window before `service` resolves (or if it never does),
  // so the `store.` bindings throughout this file don't each need a guard.
  PotStore { id: emptyStore }
  readonly property var store: (root.service && root.service.potStore) || emptyStore

  // The shared HerdrPoller (KettleService.qml) polls continuously — Panel's
  // bar-icon badge needs live counts whether or not this overlay is open —
  // so this file no longer gets "closed overlay costs zero background polls"
  // for free the way its own gated `timer.running: root.opened` used to give
  // it. Read-scheduling below (batch read on open, seq-driven re-reads) is
  // still gated by `root.opened` itself instead, for the same reason
  // (AGENTS.md: per-poll process spawns are a design smell) — reconciling
  // the snapshot into the store already happens once, in the service.
  Connections {
    target: root.service ? root.service.poller : null
    function onSnapshot(agents, focusedPaneId) {
      if (!root.opened) return
      // One-shot: covers the cold-open race where `open()`'s own batch read
      // ran before the first poll landed any local herdr pots at all.
      if (root.pendingBatchRead) {
        root.pendingBatchRead = false
        root.queueReadAll(root.localHerdrPaneIds())
      }
      // Seq-driven re-reads (plan's "Refresh budget" + risk note): a pane
      // whose state_change_seq just bumped has something new to show. Pure
      // decision lives in PreviewSource.seqRereads so "several seqs bump in
      // one poll -> one batch" is unit-tested; this just applies it.
      var decision = PreviewSource.seqRereads(store.pots, root.seqWatermark)
      root.seqWatermark = decision.watermark
      if (decision.toRead.length > 0) root.queueReadAll(decision.toRead)
    }
  }

  readonly property int slotCount: store.pots.length
  readonly property var selectedPot:
    (root.selectedIndex >= 0 && root.selectedIndex < store.pots.length)
    ? store.pots[root.selectedIndex] : null

  function selectAdjacent(delta) {
    if (root.slotCount === 0) { root.selectedIndex = -1; return }
    root.selectedIndex = (root.selectedIndex + delta + root.slotCount) % root.slotCount
  }

  // Hyprland reports toplevel addresses without a stable prefix guarantee;
  // PotStore.canonAddr is the one normalizer the rest of the plugin already
  // trusts for this comparison.
  function toplevelFor(addr) {
    if (!addr) return null
    var vals = Hyprland.toplevels.values
    for (var i = 0; i < vals.length; i++) {
      if (store.canonAddr(vals[i].address) === store.canonAddr(addr)) return vals[i]
    }
    return null
  }

  // ---- local herdr text reads (batched, single queued Process) ----------
  // docs/plan-stage-view.md "Refresh budget": one batch read of every local
  // herdr pot on open, then only the selected pot re-reads, on a 2s timer,
  // while it stays selected and the overlay stays open. Pattern copied from
  // PotStore's own `resolvePiModel` (one Process, a pending-id queue, drained
  // one at a time via onExited) — AGENTS.md: never spawn parallel herdr reads.
  property var herdrTexts: ({})   // paneId -> stripped, length-capped text
  property var readQueue: []
  property string readInFlight: ""
  property bool pendingBatchRead: false

  // paneId -> last-seen state_change_seq, the baseline seqRereads() diffs
  // against. Reset to empty on every open() so a pane that changed while the
  // overlay was closed is not treated as a "bump" needing an extra read —
  // open()'s own full batch already covers it (see PreviewSource.seqRereads).
  property var seqWatermark: ({})

  // Applied from the tail (slice(-max)): when a read exceeds the cap, the
  // newest output is the part worth keeping — a head-capped preview shows
  // how the session started, not what it needs now.
  readonly property int maxReadChars: 8000

  function queueRead(paneId) {
    if (!paneId) return
    if (root.readInFlight === paneId || root.readQueue.indexOf(paneId) !== -1) return
    if (readProc.running) { root.readQueue.push(paneId); return }
    root.readInFlight = paneId
    readProc.command = ["herdr", "agent", "read", paneId]
    readProc.running = true
  }

  function queueReadAll(paneIds) {
    for (var i = 0; i < paneIds.length; i++) root.queueRead(paneIds[i])
  }

  function localHerdrPaneIds() {
    var out = []
    for (var i = 0; i < store.pots.length; i++) {
      var p = store.pots[i]
      if (p.source === "herdr" && p.paneId) out.push(p.paneId)
    }
    return out
  }

  // `herdr agent read` output is a new ingestion point for arbitrary
  // terminal content (per the plan's risk note) even though the process
  // itself is trusted local IPC — length-capped and ANSI/control-stripped
  // here, the same "validate at ingestion" rule PotStore.qml's message
  // fields and RemoteHerdrPoller's pane_id already follow.
  function stripAnsi(s) {
    return String(s || "")
      .replace(/\x1b\][^\x07\x1b]*(\x07|\x1b\\)/g, "")     // OSC (titles, etc.)
      .replace(/\x1b\[[0-9;?]*[ -\/]*[@-~]/g, "")            // CSI (color, cursor)
      .replace(/\x1b[@-Z\\-_]/g, "")                          // other Fe escapes
      .replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, "")       // remaining control chars
  }

  property Process readProc: Process {
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.readInFlight.length === 0) return
        var clean = root.stripAnsi(text).slice(-root.maxReadChars)
        var map = Object.assign({}, root.herdrTexts)
        map[root.readInFlight] = clean
        root.herdrTexts = map
      }
    }
    onExited: {
      root.readInFlight = ""
      if (root.readQueue.length > 0) root.queueRead(root.readQueue.shift())
    }
  }

  Timer {
    interval: 2000
    repeat: true
    running: root.opened && root.selectedPot !== null
             && root.selectedPot.source === "herdr" && !!root.selectedPot.paneId
    onTriggered: root.queueRead(root.selectedPot.paneId)
  }

  // ---- remote herdr text reads (selected slab only, throttled) ----------
  // docs/plan-stage-view.md "Refresh budget": unlike local reads, a remote
  // read is an ssh round trip, so only the selected slab ever pays for one,
  // at a 4s minimum interval, with its own in-flight guard — deliberately a
  // separate Process from the local batch below rather than sharing its
  // queue, because a slow ssh call must not stall the (fast, local-IPC)
  // batched reads AGENTS.md's "never spawn parallel herdr reads" is about.
  // "Never a second spawn while one is pending" is enforced here by
  // `remoteInFlightKey`, not by the interval alone, because ssh latency can
  // exceed 4s (plan's risk note) — the interval alone would fire a second
  // spawn on top of a still-running one.
  property var remoteTexts: ({})     // pot.key -> { text, at: ms epoch read completed }
  property string remoteInFlightKey: ""
  readonly property int remoteMinIntervalMs: 4000

  function maybeReadRemote(pot) {
    if (!root.opened || !pot || pot.source !== "rherdr" || !pot.paneId || !pot.host) return
    if (root.remoteInFlightKey.length > 0) return
    var prior = root.remoteTexts[pot.key]
    var last = prior ? prior.at : 0
    if (Date.now() - last < root.remoteMinIntervalMs) return

    root.remoteInFlightKey = pot.key
    // Same ssh option set Jump.qml's rherdr focus and RemoteHerdrPoller's
    // channel use: BatchMode so a host needing a password fails fast instead
    // of hanging the overlay, ControlMaster=no so we ride the user's existing
    // master rather than risking becoming one a reload would then kill.
    // paneId is regex-validated on ingest (RemoteHerdrPoller.handleLine) and
    // herdrPath is validated on load (Relay's tokenLoader) — safe to
    // interpolate into the remote command string, same reasoning as Jump.qml.
    // herdrPathFor() comes from the shared service's Relay (see `relay`
    // below) — without the absolute path a non-interactive ssh with no login
    // shell PATH setup fails with "command not found", silently, since this
    // Process's stdout is read as the pot's text rather than surfaced as an
    // error.
    remoteReadProc.command = [
      "ssh", "-o", "BatchMode=yes", "-o", "ControlMaster=no",
      "-o", "ControlPath=" + Quickshell.env("HOME") + "/.ssh/cm-%r@%h:%p",
      "-o", "ConnectTimeout=10",
      "--", pot.host,
      ((root.relay ? root.relay.herdrPathFor(pot.host) : "") || "herdr") + " agent read " + pot.paneId
    ]
    remoteReadProc.running = true
  }

  property Process remoteReadProc: Process {
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.remoteInFlightKey.length === 0) return
        // Same ingestion trust boundary as the local read above: remote
        // terminal output is untrusted content the moment it crosses the
        // ssh pipe, regardless of how much we trust the host's identity.
        var clean = root.stripAnsi(text).slice(-root.maxReadChars)
        var map = Object.assign({}, root.remoteTexts)
        map[root.remoteInFlightKey] = { text: clean, at: Date.now() }
        root.remoteTexts = map
      }
    }
    onExited: { root.remoteInFlightKey = "" }
  }

  // Immediate read the moment a remote pot becomes selected, rather than
  // waiting up to 4s for the timer below — selection is itself the request.
  onSelectedPotChanged: root.maybeReadRemote(root.selectedPot)

  Timer {
    interval: root.remoteMinIntervalMs
    repeat: true
    running: root.opened && root.selectedPot !== null
             && root.selectedPot.source === "rherdr"
             && !!root.selectedPot.paneId && !!root.selectedPot.host
    onTriggered: root.maybeReadRemote(root.selectedPot)
  }

  // Ticks once a second, while a remote read might be stale, purely to force
  // the staleness label below to re-evaluate — Date.now() alone is not a QML
  // binding dependency, so without this the label would freeze at whatever
  // it said when the text last changed.
  property bool staleTick: false
  Timer {
    interval: 1000
    repeat: true
    running: root.opened && root.selectedPot !== null && root.selectedPot.source === "rherdr"
    onTriggered: root.staleTick = !root.staleTick
  }

  // ---- jump ---------------------------------------------------------------
  // Shared with Panel.qml via Jump.qml — each UI still instantiates its own
  // Jump (and so its own `raiser` Process; see Jump.qml's header, which
  // predates this refactor and was already true before it: Panel.qml has
  // always had its own instance too). `relay` now comes from the shared
  // service instead of a stub: remote pots are real here post-refactor, and
  // Jump's rherdr branch needs `herdrPathFor()` to reach them the same way
  // Panel.qml's jump does. `herdrWindow` still has no settings surface to
  // read from here (the shell host only injects bar-widget settings into the
  // bar-widget entry point, not overlay) — empty string degrades exactly the
  // way Jump.qml already handles a missing one: it warns instead of failing
  // silently, and tells the user to set it.
  readonly property var relay: root.service ? root.service.relay : null

  Jump {
    id: jumper
    store: store
    relay: root.relay
    pluginDir: root.pluginDir
    herdrWindow: ""
  }

  function jump(pot) {
    if (!pot) return
    root.dismiss()
    jumper.jump(pot)
  }

  // ---- open/close/toggle ---------------------------------------------------
  // Two distinct exits, same shape as Stage: close() is a bare flag flip
  // (used when something else already told the host to hide us); dismiss()
  // also tells the shell host to actually hide/unload the surface. Esc and
  // click-outside both call dismiss().
  function open(payloadJson) {
    Hyprland.refreshToplevels()
    root.kbdPriority = false
    root.selectedIndex = store.pots.length > 0 ? 0 : -1
    root.viewMode = "carousel"
    root.opened = true
    root.pendingBatchRead = true
    root.seqWatermark = ({})
    root.queueReadAll(root.localHerdrPaneIds())
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "zzwong.kettle")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // Skewed pot slab: the one visual unit the carousel repeats. Vendored from
  // Stage's WsSlab (Stage.qml:288-544) with the workspace `Repeater` of
  // toplevels replaced by a single resolved preview (screencopy | text |
  // card) — a pot slab always shows exactly one thing, never a positioned
  // layout of several windows.
  component PotSlab: Item {
    id: slab

    property var pot: null
    property bool selected: false
    property real skew: 0
    property bool chipAlways: false
    property bool hoverSelect: false
    property real dimOpacity: 0.42

    signal pressed()
    signal activated()

    readonly property real topLeft: skew
    readonly property real topRight: width
    readonly property real bottomRight: width - skew
    readonly property real bottomLeft: 0

    readonly property var previewSource: PreviewSource.resolve(slab.pot, slab.selected)

    Item {
      id: maskShape
      anchors.fill: parent
      visible: false
      layer.enabled: true

      Shape {
        anchors.fill: parent
        antialiasing: true
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
          fillColor: "white"
          strokeColor: "transparent"
          startX: slab.topLeft; startY: 0
          PathLine { x: slab.topRight; y: 0 }
          PathLine { x: slab.bottomRight; y: slab.height }
          PathLine { x: slab.bottomLeft; y: slab.height }
          PathLine { x: slab.topLeft; y: 0 }
        }
      }
    }

    Item {
      anchors.fill: parent
      clip: true
      layer.enabled: true
      layer.smooth: true
      layer.effect: MultiEffect {
        maskEnabled: true
        maskSource: maskShape
        maskThresholdMin: 0.3
        maskSpreadAtMin: 0.3
      }

      Rectangle {
        anchors.fill: parent
        color: root.background
      }

      Loader {
        anchors.fill: parent
        sourceComponent: {
          switch (slab.previewSource.kind) {
            case "screencopy": return screencopyContent
            case "text":       return textContent
            default:           return cardContent
          }
        }
      }

      // Clicking the selected slab's content is the activation gesture;
      // unselected slabs are handled by slabMouse below instead.
      MouseArea {
        anchors.fill: parent
        enabled: slab.selected
        onClicked: slab.activated()
      }

      Rectangle {
        anchors.fill: parent
        color: Util.alpha(Color.background, slab.selected ? 0 : slab.dimOpacity)
        Behavior on color { ColorAnimation { duration: 170 } }
      }
    }

    // Border stroke over the mask.
    Shape {
      anchors.fill: parent
      antialiasing: true
      preferredRendererType: Shape.CurveRenderer
      ShapePath {
        fillColor: "transparent"
        strokeColor: slab.selected ? root.pickerSelectedBorder : root.pickerUnselectedBorder
        strokeWidth: slab.selected ? 3 : 1
        startX: slab.topLeft; startY: 0
        PathLine { x: slab.topRight; y: 0 }
        PathLine { x: slab.bottomRight; y: slab.height }
        PathLine { x: slab.bottomLeft; y: slab.height }
        PathLine { x: slab.topLeft; y: 0 }
      }
    }

    // Chip: agent identity mark + state glyph, tinted by severity — the
    // same "who" + "what" composition as Panel.qml's pot rows, sharing the
    // same glyph-first rule (colour is secondary; only needs-attention
    // pulses). Parallelogram shell shares the parent's shear slope, ported
    // verbatim from Stage's workspace-number chip.
    Item {
      id: chip
      visible: slab.pot !== null
      // Top-RIGHT, not top-left. A preview's content is a terminal, which is
      // left-anchored and ragged-right, so the left corner is exactly where
      // the first line of output lands and the right corner is reliably
      // empty. Stage's own chip sits left because a wallpaper thumbnail has
      // no such bias.
      x: slab.topRight - width - Style.space(10)
      y: Style.space(10)
      width: chipRow.implicitWidth + Style.space(16)
      height: chipRow.implicitHeight + Style.space(8)
      opacity: (slab.chipAlways || slab.selected) ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 170 } }

      readonly property real chipSk: height * root.skewSlope

      Shape {
        anchors.fill: parent
        antialiasing: true
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
          fillColor: root.pickerSelectedBorder
          strokeColor: "transparent"
          startX: chip.chipSk; startY: 0
          PathLine { x: chip.width; y: 0 }
          PathLine { x: chip.width - chip.chipSk; y: chip.height }
          PathLine { x: 0; y: chip.height }
          PathLine { x: chip.chipSk; y: 0 }
        }
      }

      Row {
        id: chipRow
        anchors.centerIn: parent
        spacing: Style.space(6)

        AgentMark {
          agent: slab.pot ? (slab.pot.agentKind || "") : ""
          stroke: Color.menu.background
          width: Style.font.body
          height: width
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          text: slab.pot ? root.stateGlyph(slab.pot.state) : ""
          color: slab.pot ? root.severityColor(slab.pot.state) : root.pickerText
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.title
          anchors.verticalCenter: parent.verticalCenter

          SequentialAnimation on opacity {
            running: !!slab.pot && slab.pot.state === "needs-attention"
            loops: Animation.Infinite
            alwaysRunToEnd: true
            NumberAnimation { from: 1.0; to: 0.4; duration: 750; easing.type: Easing.InOutSine }
            NumberAnimation { from: 0.4; to: 1.0; duration: 750; easing.type: Easing.InOutSine }
          }
        }
      }
    }

    // Unselected slab: click selects it (carousel leaves hoverSelect false,
    // matching Stage's carousel — only its grid view hover-selects). Copied
    // verbatim from Stage's WsSlab, including the deliberate-motion
    // threshold: hover selection keys off real mouse motion, not onEntered,
    // because the area re-enables under an idle cursor whenever the keyboard
    // moves selection away, and onEntered there would snap selection right
    // back. While the keyboard has priority, hover must travel 24px
    // (Manhattan distance) before it re-takes selection.
    MouseArea {
      id: slabMouse
      anchors.fill: parent
      enabled: !slab.selected
      hoverEnabled: slab.hoverSelect
      cursorShape: Qt.PointingHandCursor

      property real refX: -1
      property real refY: -1
      readonly property bool kp: root.kbdPriority
      onKpChanged: { refX = -1; refY = -1 }
      onExited: { refX = -1; refY = -1 }

      onPositionChanged: function(mouse) {
        if (!slab.hoverSelect) return
        if (!root.kbdPriority) { slab.pressed(); return }
        if (refX < 0) { refX = mouse.x; refY = mouse.y; return }
        if (Math.abs(mouse.x - refX) + Math.abs(mouse.y - refY) > 24) {
          root.kbdPriority = false
          slab.pressed()
        }
      }
      onClicked: { root.kbdPriority = false; slab.pressed() }
    }

    // ---- content: screencopy | text | card -------------------------------

    Component {
      id: screencopyContent
      Item {
        id: shot
        readonly property var topl: root.toplevelFor(slab.previewSource.windowAddr)
        readonly property real inset: slab.selected ? 1 : 0
        clip: true

        // Live only while the overlay is open — captureSource goes null the
        // moment `opened` flips false, same gate Stage uses (Stage.qml:425).
        ScreencopyView {
          id: capture
          captureSource: (root.opened && shot.topl && shot.topl.wayland) ? shot.topl.wayland : null
          live: true

          // Filling the slab scaled a whole window down to slab width, which
          // for a full-screen terminal is about a third native — the same
          // illegibility the text preview stopped shrinking into. Fit while
          // the fit stays readable, then hold the floor and crop, so more
          // pots means each slab shows LESS of its window rather than the
          // same window smaller.
          readonly property real fit:
            (sourceSize.width > 0 && shot.width > 0)
              ? (shot.width - 2 * shot.inset) / sourceSize.width : 1
          readonly property real zoom: Math.max(fit, root.minPreviewScale)

          width: sourceSize.width > 0
            ? sourceSize.width * zoom : shot.width - 2 * shot.inset
          height: sourceSize.height > 0
            ? sourceSize.height * zoom : shot.height - 2 * shot.inset

          // Top-left, NOT the tail. A screencopy captures the terminal's
          // viewport rather than its scrollback, so the top of the capture is
          // already recent output, while the region below the prompt is the
          // blank remainder of a partly-filled screen. Anchoring to the bottom
          // the way the text preview does frames that blank.
          x: shot.inset
          y: shot.inset
        }

        Text {
          visible: !shot.topl
          anchors.centerIn: parent
          text: "window not found"
          color: Util.alpha(root.pickerText, 0.6)
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }

    Component {
      id: textContent
      Item {
        id: content
        anchors.fill: parent

        // Remote text comes from root.remoteTexts (keyed by the pot's own
        // unique `key`, since a remote paneId can collide with a local one);
        // local text is still keyed by paneId, unique within one herdr
        // window. `at` is undefined for local reads (no staleness concept —
        // they're a fast local IPC call, not an ssh round trip).
        readonly property bool isRemote: !!slab.previewSource.remote
        readonly property var remoteEntry:
          (isRemote && slab.pot) ? root.remoteTexts[slab.pot.key] : undefined
        readonly property string body: {
          if (isRemote) return remoteEntry ? remoteEntry.text : ""
          var pid = slab.pot ? slab.pot.paneId : ""
          return pid ? (root.herdrTexts[pid] || "") : ""
        }
        // Re-evaluated every second via root.staleTick (see its Timer) since
        // Date.now() alone is not a binding dependency.
        readonly property string stale: {
          void root.staleTick
          if (!isRemote || !remoteEntry) return ""
          return PreviewSource.staleLabel(Date.now() - remoteEntry.at, root.remoteMinIntervalMs)
        }
        // Slabs are recycled across pots; a reader's scroll position must not
        // survive into another pot's preview.
        readonly property string potKey: slab.pot ? slab.pot.key : ""
        onPotKeyChanged: flick.followTail = true

        Flickable {
          id: flick
          anchors.fill: parent
          anchors.margins: Style.space(10)
          // The slab's mask is a parallelogram: its top edge starts `skew`
          // px right of the left border and its bottom edge ends `skew` px
          // short of the right one. A pixel-image preview can afford to lose
          // that sliver; text loses whole characters to it, so the column
          // insets by the shear on both sides to stay inside the mask at
          // every row.
          anchors.leftMargin: slab.skew + Style.space(10)
          anchors.rightMargin: slab.skew + Style.space(10)
          contentWidth: Math.max(width, bodyText.implicitWidth)
          contentHeight: Math.max(height, bodyText.implicitHeight)
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          // Terminal rule: the tail is the truth, so new content keeps the
          // view pinned to the bottom — unless the reader deliberately
          // scrolled up, in which case their position wins until they return
          // to the bottom themselves.
          property bool followTail: true
          function pinToTail() { contentY = Math.max(0, contentHeight - height) }
          onMovementEnded: followTail = atYEnd
          onContentHeightChanged: if (followTail && !moving) pinToTail()
          onHeightChanged: if (followTail && !moving) pinToTail()

          Text {
            id: bodyText
            text: content.body.length > 0 ? content.body : "…"
            textFormat: Text.PlainText
            // The rows arrive hard-wrapped at the pane's own width; wrapping
            // them again at slab width breaks rules and words mid-line, and
            // shrink-to-fit made a wide pane's preview too small to read.
            // Render the grid unwrapped at a slight optical zoom of the
            // display's own body size instead — the slab reads like the real
            // terminal stepped back from — and let lines wider than the slab
            // pan horizontally. Terminals are left-anchored, so resting at
            // the left edge shows the part that matters.
            wrapMode: Text.NoWrap
            color: root.pickerText
            // A terminal snapshot must stay monospaced to read as one — the
            // menu font can be swapped independently via OMARCHY_MENU_FONT
            // and is not guaranteed monospace, so this uses the base font
            // token instead (the one every terminal-adjacent surface
            // aliases to "monospace").
            font.family: Style.font.family
            font.pixelSize: Math.round(Style.font.body * 0.85)
          }
        }

        // Stale badge: an ssh read slower than the refresh interval must not
        // block the slab — this keeps showing the last text it has and says
        // how old it is instead. Clears itself the moment a fresh read lands
        // (remoteEntry.at moves, stale recomputes to "").
        Rectangle {
          visible: content.stale.length > 0
          anchors.top: parent.top
          anchors.right: parent.right
          anchors.margins: Style.space(8)
          radius: height / 2
          color: Util.alpha(Color.background, 0.75)
          width: staleText.implicitWidth + Style.space(12)
          height: staleText.implicitHeight + Style.space(6)

          Text {
            id: staleText
            anchors.centerIn: parent
            text: content.stale
            color: Util.alpha(root.pickerText, 0.8)
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    Component {
      id: cardContent
      Column {
        anchors.centerIn: parent
        spacing: Style.space(6)
        width: parent.width - Style.space(24)

        AgentMark {
          anchors.horizontalCenter: parent.horizontalCenter
          agent: slab.pot ? (slab.pot.agentKind || "") : ""
          stroke: root.pickerText
          width: Style.font.display
          height: width
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: slab.pot ? slab.pot.label : ""
          color: root.pickerText
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.subtitle
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: {
            if (!slab.pot) return ""
            var bits = []
            if (slab.pot.project) bits.push(slab.pot.project)
            if (slab.pot.host) bits.push("@" + slab.pot.host)
            return bits.join("  ")
          }
          color: Util.alpha(root.pickerText, 0.7)
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: slab.pot
            ? (store.isLive(slab.pot.state) ? store.label(slab.pot) : store.ranWord(slab.pot))
            : ""
          color: Util.alpha(root.pickerText, 0.55)
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "kettle-stage"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Re-grab keyboard focus whenever the overlay becomes visible; a missed
    // grab leaves arrows dead (Stage's comment, still true here).
    onVisibleChanged: if (visible) Qt.callLater(function() { keyCatcher.forceActiveFocus() })

    // Near-opaque backdrop: same call Stage made and the same caveat — this
    // assumes Hyprland blur is off. Revisit if Kettle ships with it enabled.
    Rectangle {
      anchors.fill: parent
      color: Qt.alpha(Color.background, 0.92)
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem

      Keys.onPressed: function(event) {
        var grid = root.viewMode === "grid"

        if (event.key === Qt.Key_Escape) {
          root.dismiss()
          event.accepted = true
        } else if (event.key === Qt.Key_Up) {
          // Zoom axis (Stage.qml's Up/Down handler, minus the viewPref
          // lock check — kettle has no setting to disable this).
          root.kbdPriority = true
          if (grid) {
            // Move up a row; past the top, fall back into the carousel.
            var up = root.selectedIndex - root.gridCols
            if (up >= 0) root.selectedIndex = up
            else root.viewMode = "carousel"
          } else {
            root.viewMode = "grid"
          }
          event.accepted = true
        } else if (event.key === Qt.Key_Down) {
          root.kbdPriority = true
          if (grid) {
            // Move down a row; past the bottom, fall back into the
            // carousel. Carousel-Down is a no-op: Stage uses it to zoom
            // into pane mode, which pots have no equivalent of (see file
            // header).
            var down = root.selectedIndex + root.gridCols
            if (down < root.slotCount) root.selectedIndex = down
            else root.viewMode = "carousel"
          }
          event.accepted = true
        } else if (event.key === Qt.Key_Left
                   || (event.key === Qt.Key_Tab && event.modifiers & Qt.ShiftModifier)
                   || event.key === Qt.Key_Backtab) {
          root.kbdPriority = true
          root.selectAdjacent(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab) {
          root.kbdPriority = true
          root.selectAdjacent(1)
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.jump(root.selectedPot)
          event.accepted = true
        }
      }
    }

    // ---- empty state: "Nothing cooking" ------------------------------
    // Mirrors the bar widget's idle glyph: KettleMark with no state ink,
    // dimmed, same as Panel.qml's `opacity: root.hasAnything ? 1.0 : 0.45`.
    Column {
      visible: root.opened && store.pots.length === 0
      anchors.centerIn: parent
      spacing: Style.space(14)

      KettleMark {
        anchors.horizontalCenter: parent.horizontalCenter
        potState: "idle"
        stroke: root.pickerText
        width: Style.font.displayLarge * 2
        height: width
        opacity: 0.45
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Nothing cooking"
        color: Util.alpha(root.pickerText, 0.6)
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.title
        font.weight: Font.DemiBold
      }
    }

    // ---- carousel: skewed slice picker, selected pot expands ----------
    Loader {
      active: root.opened && root.viewMode === "carousel" && store.pots.length > 0
      anchors.centerIn: parent

      sourceComponent: Item {
        id: pickerCard

        readonly property real expandedW: Math.min(panel.width * 0.55, 980)
        readonly property real expandedH: expandedW / root.previewAspect
        readonly property real sliceW: 108
        readonly property real sliceH: expandedH * 0.91
        readonly property real sliceSpacing: -30
        readonly property real itemStep: sliceW + sliceSpacing
        readonly property real previewX: (width - expandedW) / 2

        width: expandedW + Math.max(2, root.slotCount - 1) * 2 * itemStep + 80
        height: expandedH

        // Swallows clicks on empty space between slabs so they don't bubble
        // to the backdrop's dismiss handler underneath.
        MouseArea { anchors.fill: parent; onClicked: {} }

        Repeater {
          model: store.pots

          delegate: PotSlab {
            id: caroItem
            required property var modelData
            required property int index

            readonly property int relativeIndex: index - root.selectedIndex

            pot: modelData
            selected: index === root.selectedIndex
            skew: pickerCard.expandedH * root.skewSlope

            x: selected ? pickerCard.previewX
                        : (relativeIndex < 0
                           ? pickerCard.previewX + relativeIndex * pickerCard.itemStep
                           : pickerCard.previewX + pickerCard.expandedW + pickerCard.sliceSpacing
                             + (relativeIndex - 1) * pickerCard.itemStep)
            width: selected ? pickerCard.expandedW : pickerCard.sliceW
            height: selected ? pickerCard.expandedH : pickerCard.sliceH
            y: selected ? 0 : (pickerCard.expandedH - pickerCard.sliceH) / 2
            z: selected ? 100 : 50 - Math.min(Math.abs(relativeIndex), 40)

            Behavior on x { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
            Behavior on y { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
            Behavior on width { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
            Behavior on height { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }

            onPressed: root.selectedIndex = index
            onActivated: root.jump(modelData)
          }
        }
      }
    }

    // ---- grid: every pot laid out responsively -------------------------
    // Preview budget (docs/plan-stage-view.md "Refresh budget"): showing
    // every pot at once here needs no new reads. Local herdr text was
    // already read for every pot in one batch on open() (see "local herdr
    // text reads" above) and keeps getting re-read on seq bumps regardless
    // of which view is on screen — the grid doesn't add pots to that read
    // set, just displays ones already covered. Remote (rherdr) pots stay
    // metadata cards here exactly like in the carousel:
    // PreviewSource.resolve() only upgrades a remote pot to a text preview
    // when it is *the* selectedPot, and the grid shares one
    // root.selectedIndex with the carousel (hover and arrow keys move the
    // same property carousel navigation does) — so that gate, and the
    // selected-pot-only read timers above, are untouched by this view
    // existing. Screencopy slabs (hook pots) may all be live at once while
    // the grid is open, same as Stage's own grid (Stage.qml:700-742) —
    // captureSource is gated on `root.opened`, not on viewMode, so this is
    // not a new cost class, just more slabs paying the cost that already
    // existed.
    Loader {
      active: root.opened && root.viewMode === "grid" && store.pots.length > 0
      anchors.fill: parent

      sourceComponent: Item {
        id: gridView

        readonly property real cardW: root.gridFit.w
        readonly property real cardH: cardW / root.previewAspect

        Grid {
          anchors.centerIn: parent
          columns: root.gridCols
          columnSpacing: root.gridGap
          rowSpacing: root.gridGap

          Repeater {
            model: store.pots

            delegate: PotSlab {
              id: gridItem
              required property var modelData
              required property int index

              pot: modelData
              width: gridView.cardW
              height: gridView.cardH
              selected: index === root.selectedIndex
              skew: gridView.cardH * root.skewSlope
              chipAlways: true
              hoverSelect: true
              dimOpacity: 0.22

              scale: selected ? 1.03 : 1.0
              z: selected ? 2 : 1
              Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

              onPressed: root.selectedIndex = index
              onActivated: root.jump(modelData)
            }
          }
        }
      }
    }

    // ---- label bar: selected pot's title / cwd / elapsed --------------
    // One pill for the one selected slab's content (a pot slab has no
    // per-window repeater to list, unlike Stage's per-toplevel pill row) —
    // marquee mechanic copied verbatim from Stage's labelBar pill
    // (Stage.qml:901-965) for titles too long to fit.
    Item {
      id: labelBar
      visible: root.opened && root.selectedPot !== null
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(44)
      anchors.horizontalCenter: parent.horizontalCenter
      width: pill.width
      height: pill.height

      readonly property var pot: root.selectedPot
      readonly property string pillLabel: {
        if (!labelBar.pot) return ""
        var bits = [labelBar.pot.label]
        if (labelBar.pot.project) bits.push(labelBar.pot.project)
        var word = store.isLive(labelBar.pot.state)
          ? store.label(labelBar.pot) : store.ranWord(labelBar.pot)
        if (word) bits.push(word)
        return bits.join("  ·  ")
      }

      Rectangle {
        id: pill
        width: labelClip.width + Style.space(20)
        height: Style.space(30)
        radius: height / 2
        color: Util.alpha(root.pickerText, 0.12)
        border.color: Util.alpha(root.pickerSelectedBorder, 0.5)
        border.width: 1

        Item {
          id: labelClip
          anchors.centerIn: parent
          width: Math.min(measureText.implicitWidth, 420)
          height: measureText.implicitHeight
          clip: true

          readonly property bool overflowing: measureText.implicitWidth > width
          readonly property bool marquee: overflowing && pillHover.containsMouse
          readonly property real gap: Style.space(24)

          MouseArea {
            id: pillHover
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
          }

          Text {
            id: measureText
            visible: false
            text: labelBar.pillLabel
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.subtitle
          }

          Text {
            visible: !labelClip.marquee
            width: labelClip.width
            text: labelBar.pillLabel
            color: root.pickerText
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.subtitle
            elide: Text.ElideRight
          }

          Row {
            id: scroller
            visible: labelClip.marquee
            spacing: labelClip.gap

            Text {
              text: labelBar.pillLabel
              color: root.pickerText
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.subtitle
            }
            Text {
              text: labelBar.pillLabel
              color: root.pickerText
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.subtitle
            }
          }

          SequentialAnimation {
            running: labelClip.marquee
            loops: Animation.Infinite
            onRunningChanged: if (!running) scroller.x = 0

            PauseAnimation { duration: 400 }
            NumberAnimation {
              target: scroller
              property: "x"
              from: 0
              to: -(measureText.implicitWidth + labelClip.gap)
              duration: Math.max(1500, (measureText.implicitWidth + labelClip.gap) * 16)
            }
            PauseAnimation { duration: 250 }
          }
        }
      }
    }
  }
}
