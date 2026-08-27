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

  // Must match the manifest id — the registry's moduleWidgets() keys on it.
  moduleName: "zzwong.kettle"

  // Shared state lives in KettleService.qml (manifest kind "service") —
  // PotStore, both pollers, Relay, and the single `IpcHandler{target:
  // "kettle"}` all moved there so StageView.qml's overlay can see hook and
  // remote pots too (they used to arrive only through this panel's own
  // IpcHandler/Relay — see KettleService.qml's header). No `ipcTarget` here
  // any more: the service owns that target now, and Quickshell IpcHandlers
  // are single-owner, so this panel must not declare a second one.
  //
  // The panel loader (shell.qml, panel/overlay/menu kinds) injects `service`
  // automatically, but the bar-widget loader (plugins/bar/Bar.qml's
  // injectProps) only sets bar/moduleName/settings — so this widget fetches
  // the service itself, once `bar` (and therefore `bar.shell`, the same
  // shell root the panel loader calls `serviceFor` on) is injected. Reactive
  // like any QML binding: it re-resolves if `bar` changes or the service is
  // (re)created later.
  readonly property var service:
    (root.bar && root.bar.shell && typeof root.bar.shell.serviceFor === "function")
      ? root.bar.shell.serviceFor(root.moduleName) : null

  // Never fed anything — a stable, correctly-shaped stand-in for the shared
  // store during the brief window before `service` resolves (or if it never
  // does), so the many `store.` bindings below don't each need a null guard.
  PotStore { id: emptyStore }

  readonly property var store: (root.service && root.service.potStore) || emptyStore
  readonly property var relay: root.service ? root.service.relay : null
  // HerdrPoller.serverDown starts true ("no session yet"), so defaulting to
  // true here while the service is unresolved describes the same state.
  readonly property bool serverDown: (root.service && root.service.poller) ? root.service.poller.serverDown : true

  // The bar-widget setting the service has no way to read for itself (see
  // KettleService.qml's `notificationsEnabled`) — pushed in whenever either
  // side changes, so a live settings edit still takes effect immediately.
  Binding {
    target: root.service
    property: "notificationsEnabled"
    value: root.notify
    when: !!root.service
  }

  // IPC-triggered open/close/toggle of this panel's dropdown: PanelController
  // state is private to this one live instance, so the service forwards
  // rather than owning it (see KettleService.qml's IpcHandler).
  Connections {
    target: root.service
    function onOpenPanelRequested() { root.open() }
    function onClosePanelRequested() { root.close() }
    function onTogglePanelRequested() { root.toggle() }
  }

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

  // Empty falls back to the host name, which matches herdr's default remote
  // window title of "{hostname}: {workspace}".
  readonly property string remoteWindow: setting("remoteWindow", "")

  // More than one distinct host among the pots (local counts as one) switches
  // the list into grouped rendering: host header rows, no per-row host tag.
  readonly property bool grouped: {
    var seen = {}, n = 0
    for (var i = 0; i < store.pots.length; i++) {
      var h = String(store.pots[i].host || "")
      if (!seen[h]) { seen[h] = true; n++ }
    }
    return n > 1
  }

  readonly property string pluginDir:
    Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")

  // Clicking a pot is the acknowledgement: focusing the tab flips herdr from
  // `done` to `idle`, and CLI reads never mark a tab seen — so the next poll
  // drops the pot with no widget-side bookkeeping at all.
  //
  // Mechanism lives in Jump.qml, shared with the Stage overlay — this panel
  // just closes itself first, since Jump never closes a caller's surface.
  function jump(pot) {
    if (!pot) return
    root.close()
    jumper.jump(pot)
  }

  Jump {
    id: jumper
    store: store
    relay: root.relay
    pluginDir: root.pluginDir
    herdrWindow: root.herdrWindow
    remoteWindow: root.remoteWindow
  }

  // The overlay is a separate entry point (StageView.qml) per the manifest,
  // not a sibling in this object tree — the shell host is the only thing
  // that can reach both, so this forwards rather than opening directly.
  // Fixed argv, no user input. (Kept identical to KettleService.qml's own
  // `stage()`, which the "kettle stage" IPC verb calls instead of this one —
  // this copy backs the in-panel "Open Stage" button.)
  function stage() {
    Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "zzwong.kettle"])
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
      : (root.serverDown ? "Kettle — no herdr session" : "Kettle — nothing cooking")

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
          implicitHeight: Math.max(title.implicitHeight, sub.implicitHeight, stageButton.implicitHeight)

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

          // Overview of every pot at once. Lives beside the title rather
          // than the pot rows below, since it acts on the whole panel, not
          // one pot — closing this panel first matches every row's jump.
          PanelActionButton {
            id: stageButton
            anchors.left: title.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            iconText: ""
            tooltipText: "Open Stage"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: { root.close(); root.stage() }
          }

          Text {
            id: sub
            text: {
              if (root.serverDown) return "NO SESSION"
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
          text: root.serverDown
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

            Column {
              id: entry
              required property var modelData
              required property int index
              width: parent.width
              spacing: Style.space(2)

              // Host header above the first pot of each remote group. The
              // local group leads the sorted list and needs no label.
              Text {
                visible: root.grouped && String(entry.modelData.host || "") !== ""
                  && (entry.index === 0
                      || String(store.pots[entry.index - 1].host || "") !== String(entry.modelData.host))
                text: "@" + entry.modelData.host
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                leftPadding: Style.space(8)
                topPadding: Style.space(4)
              }

            Rectangle {
              id: row
              readonly property var modelData: entry.modelData
              readonly property int index: entry.index

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
                    // The group header carries the host when grouping is on.
                    if (row.modelData.host && !root.grouped) bits.push("@" + row.modelData.host)
                    var ran = store.ranWord(row.modelData)
                    if (ran && !store.isLive(row.modelData.state)) bits.push(ran)
                    var msg = String(row.modelData.message || "")
                    if (row.modelData.state === "needs-attention") bits.push(msg || "needs approval")
                    else if (row.modelData.state === "burnt") bits.push("failed")
                    else if (row.modelData.state === "murky") bits.push("unclear")
                    // A simmering pot's detail is its prompt.
                    else if (msg && row.modelData.state === "simmering") bits.push(msg)
                    return bits.join(" · ")
                  }
                  // Plain text always: the message field is agent- and
                  // remote-controlled input.
                  textFormat: Text.PlainText
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
