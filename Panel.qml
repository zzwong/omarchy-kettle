import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Kettle — long-running work as pots on the bar.
//
// Phase 1 is herdr-only: agent sessions need zero instrumentation because
// herdr already tracks the lifecycle, including the idle/done distinction
// that is this widget's whole premise ("done" means finished while unseen).
Panel {
  id: root

  moduleName: "kettle"
  ipcTarget: "kettle"
  manageIpc: false   // this panel owns the single IpcHandler for its target

  // Nerd Font glyphs, verified present in JetBrainsMonoNerdFont.
  // State is carried by glyph first and colour second: Omarchy themes expose
  // only foreground/background/accent/urgent/muted, with no success or warning
  // role, so needs-attention and burnt necessarily share `urgent` and are
  // separated by shape. That also survives colourblindness and a 15px slot.
  readonly property string glyphSimmering: "󰅶"
  readonly property string glyphAttention: "󰗖"
  readonly property string glyphReady:     "󰗠"
  readonly property string glyphBurnt:     "󰀦"
  readonly property string glyphMurky:     "󰮎"

  readonly property bool showCount: setting("showCount", true) === true
  readonly property bool notify: setting("notifications", true) === true

  readonly property int potCount: store.pots.length
  readonly property bool hasAnything: potCount > 0

  function severityColor(state) {
    switch (state) {
      case "needs-attention": return Color.urgent
      case "burnt":           return Color.urgent
      case "ready":           return Color.accent
      case "murky":           return Color.muted
      default:                return root.barForeground
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

  function stateWord(pot) {
    switch (pot.state) {
      case "needs-attention": return "needs approval"
      case "ready":           return "finished"
      case "burnt":           return "failed"
      case "murky":           return "unclear"
      default:                return "running"
    }
  }

  // Substring matched against Hyprland window title or class to locate the
  // herdr TUI. Required for single-process terminals (ghostty
  // --gtk-single-instance, foot --server, kitty single-instance) where every
  // window reports the same PID and the process tree cannot tell them apart.
  readonly property string herdrWindow: setting("herdrWindow", "")

  readonly property string pluginDir:
    Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")

  // Clicking a pot is the acknowledgement: focusing the tab flips herdr from
  // `done` to `idle`, and CLI reads never mark a tab seen — so the next poll
  // drops the pot with no widget-side bookkeeping at all.
  //
  // Two steps, because `herdr agent focus` switches herdr's internal tab but
  // does NOT raise the OS window. Without the second step the jump silently
  // does nothing visible when herdr is on another workspace.
  function jump(pot) {
    if (!pot) return
    root.close()

    // Hook-sourced sessions carry their own window address, resolved once at
    // SessionStart via an OSC 2 title nonce. No herdr involved, and no
    // resolver subprocess needed.
    if (pot.source === "agent") {
      if (pot.windowAddr) focusWindow(pot.windowAddr)
      // Only a finished pot is dismissed by looking at it. A session that is
      // still working stays on the bar after you jump to it — clearing it
      // would hide live work behind a single click.
      if (!store.isLive(pot.state)) store.dropHookPot(pot.key)
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
        (relay.herdrPathFor(pot.host) || "herdr") + " agent focus " + pot.paneId
      ])
      return
    }

    if (!pot.paneId) return
    Quickshell.execDetached(["herdr", "agent", "focus", pot.paneId])
    raiser.running = false
    raiser.command = [root.pluginDir + "bin/kettle-herdr-window", root.herdrWindow]
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

  Process {
    id: raiser
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var addr = String(text || "").trim()
        if (addr.length > 0) return root.focusWindow(addr)
        // Refusing to guess is right; refusing silently is not. This is the
        // one failure a user can actually fix (set herdrWindow), so say so.
        console.warn("kettle: cannot locate herdr's window — herdr's internal "
          + "tab switched, but nothing was raised. On a single-process "
          + "terminal set \"herdrWindow\" to a title substring (see README).")
      }
    }
  }

  // Focus changes are pushed by Hyprland, so acknowledgement costs nothing —
  // no extra polling, no subprocess.
  Connections {
    target: Hyprland
    function onActiveToplevelChanged() {
      var tl = Hyprland.activeToplevel
      if (tl && tl.address) store.seenWindow(store.canonAddr(tl.address))
    }
  }

  Relay {
    id: relay
    store: store
  }

  // One streaming channel per configured host. The token files double as the
  // host registry, so adding or revoking a host is a file operation.
  //
  // Instantiator, not Repeater: Repeater only instantiates Item delegates and
  // silently produces nothing for a QtObject, which is what this is.
  Instantiator {
    id: remoteHosts
    model: relay.hostList
    delegate: RemoteHerdrPoller {
      required property string modelData
      host: modelData
      pluginDir: root.pluginDir
      herdrPath: relay.herdrPathFor(modelData)
      Component.onCompleted: start()
      // Renamed from agentsChanged: that collides with the implicit
      // property-change signal QML generates, so the handler never fired.
      onSnapshotAgents: function(list) { store.reconcileRemote(host, list) }
      onDown: store.dropRemoteHost(host)
      // Unreachable long enough that its pots cannot be trusted.
      onLost: store.dropRemoteHost(host)
    }
  }

  PotStore {
    id: store
    pluginDir: root.pluginDir
    onPotChanged: function(pot, fromState) {
      if (root.notify) notifier.consider(pot, fromState)
    }
  }

  Notifier {
    id: notifier
    enabled: root.notify
    focusedPaneId: poller.focusedPaneId
    // Hook and remote pots have no paneId, so paneId-based suppression could
    // never match them and a blocked pot would notify even while you watched
    // its window. Window address covers those.
    focusedWindow: store.canonAddr(Hyprland.activeToplevel ? Hyprland.activeToplevel.address : "")
    glyphAttention: root.glyphAttention
    glyphReady: root.glyphReady
    glyphBurnt: root.glyphBurnt
  }

  HerdrPoller {
    id: poller
    onSnapshot: function(agents, focusedPaneId) { store.reconcile(agents) }
    onServerLost: store.clear()
  }

  // Drives the live elapsed clocks without re-polling herdr. Only runs while
  // something is actually cooking — a panel showing only finished pots has
  // nothing that changes per second.
  Timer {
    interval: 1000
    running: root.opened && store.hasLive
    repeat: true
    onTriggered: tick = !tick
  }
  property bool tick: false

  // Keyboard cursor into the pot list. -1 means "no selection yet", so the
  // first arrow press lands on the top pot rather than moving off it.
  property int cursor: -1

  onOpenedChanged: cursor = -1

  function moveCursor(delta) {
    var n = store.pots.length
    if (n === 0) { cursor = -1; return }
    if (cursor < 0) { cursor = delta > 0 ? 0 : n - 1; return }
    cursor = (cursor + delta + n) % n
  }

  function activateCursor() {
    if (cursor < 0 || cursor >= store.pots.length) return
    var pot = store.pots[cursor]
    if (pot && pot.state !== "murky") root.jump(pot)
  }

  IpcHandler {
    target: "kettle"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function count(): string { return String(store.liveCount) }

    // Entry point for agents outside herdr. The payload is base64 so that a
    // command line, a prompt, or a cwd containing quotes cannot break the
    // transport.
    //
    // Unlike the relay, this does NOT sanitize: reaching this IPC already
    // requires running as the same user, who could call store.ingest by other
    // means anyway. Do not assume ingest() validates — remote input goes
    // through Relay.sanitize() precisely because this path does not.
    function agentEvent(b64: string): string {
      try {
        var ev = JSON.parse(Qt.atob(b64))
        store.ingest(ev)
        return "ok"
      } catch (e) {
        return "bad-payload"
      }
    }
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Drawn, not glyphed — see KettleMark for why the coffee glyph failed.
    // The count still rides as text so it keeps the bar's font metrics.
    text: root.showCount && !vertical && store.liveCount > 0 ? " " + store.liveCount : ""
    iconComponent: Component {
      KettleMark {
        potState: store.severity
        stroke: root.severityColor(store.severity)
        opacity: root.hasAnything ? 1.0 : 0.45
        Behavior on opacity { NumberAnimation { duration: 180 } }
      }
    }
    slotSize: Style.bar.iconSlot * (root.showCount && !vertical && store.liveCount > 0 ? 1.6 : 1)
    foreground: root.severityColor(store.severity)
    tooltipText: root.hasAnything
      ? (store.liveCount + " cooking" + (store.pots.length > store.liveCount
          ? ", " + (store.pots.length - store.liveCount) + " waiting" : ""))
      : (poller.serverDown ? "Kettle — no herdr session" : "Kettle — nothing cooking")

    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy > 0 ? 1 : -1)
        else if (dx !== 0) root.moveCursor(dx > 0 ? 1 : -1)
      }
      onActivateRequested: root.activateCursor()

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- header ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(title.implicitHeight, sub.implicitHeight)

          Text {
            id: title
            text: "Kettle"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: sub
            text: {
              if (poller.serverDown) return "NO SESSION"
              if (store.pots.length === 0) return "NOTHING COOKING"
              return store.liveCount + " COOKING"
            }
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // ---------- empty state ----------
        Text {
          visible: store.pots.length === 0
          width: parent.width
          wrapMode: Text.WordWrap
          text: poller.serverDown
            ? "No herdr server is running. Start one and pots will appear here."
            : "Nothing is cooking. Long-running agents and commands show up here."
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // ---------- pots ----------
        Column {
          width: parent.width
          spacing: Style.space(2)

          Repeater {
            model: store.pots

            Rectangle {
              id: row
              required property var modelData
              required property int index

              readonly property bool isMurky: modelData.state === "murky"

              width: parent.width
              implicitHeight: Style.space(42)
              radius: Style.space(6)
              readonly property bool hasCursor: root.cursor === index

              color: (hover.containsMouse || hasCursor)
                ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b,
                          hasCursor ? 0.14 : 0.08)
                : "transparent"

              // A keyboard selection needs an edge as well as a fill: on a
              // busy theme the fill alone is easy to lose.
              border.width: hasCursor ? 1 : 0
              border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g,
                                    root.bar.foreground.b, 0.28)

              // Pointing at a row with the mouse moves the keyboard cursor
              // too, so the two never disagree about what Enter would do.

              MouseArea {
                id: hover
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                cursorShape: row.isMurky ? Qt.ArrowCursor : Qt.PointingHandCursor
                onEntered: root.cursor = row.index
                onClicked: function(mouse) {
                  // Middle-click drops a pot without jumping — for a session
                  // killed mid-turn, whose completion event never arrives.
                  if (mouse.button === Qt.MiddleButton) {
                    if (row.modelData.source === "agent") store.dropHookPot(row.modelData.key)
                  } else if (!row.isMurky) {
                    root.jump(row.modelData)
                  }
                }
              }

              AgentMark {
                id: rowMark
                agent: row.modelData.agentKind || ""
                stroke: Qt.darker(root.bar.foreground, 1.35)
                width: Style.font.bodySmall * 1.15
                height: width
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                opacity: row.isMurky ? 0.45 : 0.9
              }

              Text {
                id: rowGlyph
                text: root.stateGlyph(row.modelData.state)
                color: root.severityColor(row.modelData.state)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter

                // Only needs-attention moves. Motion is reserved for the one
                // state that is actually waiting on a human.
                SequentialAnimation on opacity {
                  running: row.modelData.state === "needs-attention"
                  loops: Animation.Infinite
                  alwaysRunToEnd: true
                  NumberAnimation { from: 1.0; to: 0.4; duration: 750; easing.type: Easing.InOutSine }
                  NumberAnimation { from: 0.4; to: 1.0; duration: 750; easing.type: Easing.InOutSine }
                }
              }

              Column {
                anchors.left: rowMark.right
                anchors.leftMargin: Style.space(11)
                anchors.right: age.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)

                Text {
                  // Model belongs beside the agent, not in the subtitle: it is
                  // part of what is running, not what it is doing.
                  text: row.modelData.model
                      ? row.modelData.label + "  ·  " + store.prettyModel(row.modelData.model, row.modelData.agentKind)
                      : row.modelData.label
                  color: row.isMurky ? Color.muted : root.severityColor(row.modelData.state)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  text: {
                    // The status glyph now carries the state, so repeating it
                    // here only crowds the row and elides what is actually
                    // informative — the duration and the host.
                    var bits = []
                    if (row.modelData.project) bits.push(row.modelData.project)
                    if (row.modelData.host) bits.push("@" + row.modelData.host)
                    var ran = store.ranWord(row.modelData)
                    if (ran && !store.isLive(row.modelData.state)) bits.push(ran)
                    // Kept only where the word says more than the glyph can.
                    if (row.modelData.state === "needs-attention") bits.push("needs approval")
                    else if (row.modelData.state === "burnt") bits.push("failed")
                    else if (row.modelData.state === "murky") bits.push("unclear")
                    return bits.join(" · ")
                  }
                  color: Qt.darker(root.bar.foreground, 1.6)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width
                }
              }

              Text {
                id: age
                text: (root.tick, store.label(row.modelData))
                color: Qt.darker(root.bar.foreground, 1.6)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: rowGlyph.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }
        }

        // ---------- footer ----------
        PanelSeparator {
          visible: store.pots.length > 0
          foreground: root.bar.foreground
        }

        Item {
          visible: store.pots.length > 0
          width: parent.width
          implicitHeight: foot.implicitHeight

          Text {
            id: foot
            text: store.murkyCount > 0
              ? store.murkyCount + (store.murkyCount === 1 ? " pane unclear" : " panes unclear")
              : ""
            color: Color.muted
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            text: "↑↓ select · ↵ jump · esc close"
            color: Qt.darker(root.bar.foreground, 1.7)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }
    }
  }
}
