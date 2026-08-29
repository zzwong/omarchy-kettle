import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "HostModel.js" as HostModel

// Kettle's shared state — one instance for both entry points.
//
// The shell loads `bar-widget` (Panel.qml) and `overlay` (StageView.qml) as
// separate QML trees with no built-in reference between them. Declaring this
// file as manifest kind "service" gets it exactly one shared instance on the
// shell's serviceHost (shell.qml's ensureService/serviceFor), created once
// and synced for as long as this plugin is enabled — independent of whether
// either UI happens to be loaded. That is also why ingestion lives here
// rather than in either UI: `IpcHandler{target:"kettle"}` and Relay's
// SocketServer are single-owner (Quickshell: a target/path can only be bound
// once), so before this file existed only one of the two UIs could hold them
// — Panel.qml did, which is the entire reason StageView.qml's hook and
// remote pots never arrived (see its former KNOWN GAP comment, now removed).
//
// The panel loader (shell.qml, panel/overlay/menu kinds) injects `service`
// into StageView automatically (`if ("service" in item) item.service =
// shell.serviceFor(...)`). The bar-widget loader (plugins/bar/Bar.qml's
// injectProps) does NOT — it only sets bar/moduleName/settings — so
// Panel.qml fetches this instance itself once `bar` (and therefore
// `bar.shell`) is injected; see Panel.qml's `service` property.
// Item, not QtObject: QtObject has no default property to hold the declared
// children below, and it's what the first-party services (polkit, background,
// lock) use as their root.
Item {
  id: root

  readonly property string pluginDir:
    Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")

  // ---- shared pot state ---------------------------------------------------
  property alias potStore: store

  PotStore {
    id: store
    pluginDir: root.pluginDir
    onPotChanged: function(pot, fromState) {
      if (root.notificationsEnabled) notifier.consider(pot, fromState)
    }
  }

  // Looking at the window IS the acknowledgement — the same signal herdr uses
  // internally, reimplemented for sessions it does not manage (see
  // PotStore.seenWindow). Lives here, not in either UI's Hyprland Connections,
  // so a hook pot gets acknowledged by focus even when neither UI is open.
  Connections {
    target: Hyprland
    function onActiveToplevelChanged() {
      var tl = Hyprland.activeToplevel
      if (tl && tl.address) store.seenWindow(store.canonAddr(tl.address))
    }
  }

  // ---- remote ingestion -----------------------------------------------------
  property alias relay: relay

  Relay {
    id: relay
    store: store
  }

  // One streaming channel per configured host. The token files double as the
  // host registry, so adding or revoking a host is a file operation.
  //
  // Instantiator, not Repeater: Repeater only instantiates Item delegates and
  // silently produces nothing for a QtObject, which is what this is.
  // Reconciled incrementally, never reassigned: a rebuilt delegate would orphan
  // that host's pots (#8, HostModel.js).
  ListModel {
    id: remoteHostModel
    // No-op today: tokens load async, so hostList is still empty here. Guards
    // against a load path that populates it before this Connections exists.
    Component.onCompleted: root.syncRemoteHosts()
  }

  function syncRemoteHosts() {
    var current = []
    for (var i = 0; i < remoteHostModel.count; i++)
      current.push(remoteHostModel.get(i).hostName)
    var d = HostModel.diff(current, relay.hostList)
    for (var r = 0; r < d.remove.length; r++) remoteHostModel.remove(d.remove[r])
    for (var a = 0; a < d.add.length; a++) remoteHostModel.append({hostName: d.add[a]})
  }

  Connections {
    target: relay
    function onHostListChanged() { root.syncRemoteHosts() }
  }

  Instantiator {
    id: remoteHosts
    model: remoteHostModel
    delegate: RemoteHerdrPoller {
      required property string hostName
      host: hostName
      pluginDir: root.pluginDir
      herdrPath: relay.herdrPathFor(hostName)
      Component.onCompleted: start()
      // Destruction now means the host left the registry, so its pots must go
      // with it — nothing else clears them.
      Component.onDestruction: if (store) store.dropRemoteHost(host)
      // Renamed from agentsChanged: that collides with the implicit
      // property-change signal QML generates, so the handler never fired.
      onSnapshotAgents: function(list) { store.reconcileRemote(host, list) }
      onDown: store.dropRemoteHost(host)
      // Unreachable long enough that its pots cannot be trusted.
      onLost: store.dropRemoteHost(host)
    }
  }

  // ---- local herdr polling --------------------------------------------------
  // Always running (background 2s/15s cadence), not gated by either UI's open
  // state: Panel's bar-icon badge needs a live count whether or not its
  // dropdown or the Stage overlay is open, so a "poll only while open" gate
  // would just move the same cost to whichever UI still needs to be live.
  property alias poller: poller

  HerdrPoller {
    id: poller
    onSnapshot: function(agents, focusedPaneId) { store.reconcile(agents) }
    onServerLost: store.clear()
  }

  // ---- notifications ----------------------------------------------------
  // Lives here, not in Panel.qml, so a notification fires whether or not the
  // bar widget is actually placed in the bar's module list — the overlay
  // alone is enough to want them. The "notifications" toggle is a bar-widget
  // setting though (this plugin's only settings surface today; services get
  // no settings injection from shell.qml), so Panel pushes its live value in
  // via a Binding when it is loaded. The default below matches the manifest
  // schema's own default (true), so an overlay-only setup still notifies.
  property bool notificationsEnabled: true

  // Duplicated from Panel.qml's glyph table rather than shared, same
  // reasoning StageView.qml already documents for its own copy: these are
  // private to each file today, not exported (see docs/plan-stage-view.md's
  // note that hoisting them into PotStore is the natural follow-up).
  readonly property string glyphAttention: "󰗖"
  readonly property string glyphReady:     "󰗠"
  readonly property string glyphBurnt:     "󰀦"

  Notifier {
    id: notifier
    enabled: root.notificationsEnabled
    focusedPaneId: poller.focusedPaneId
    // Hook and remote pots have no paneId, so paneId-based suppression could
    // never match them and a blocked pot would notify even while you watched
    // its window. Window address covers those.
    focusedWindow: store.canonAddr(Hyprland.activeToplevel ? Hyprland.activeToplevel.address : "")
    glyphAttention: root.glyphAttention
    glyphReady: root.glyphReady
    glyphBurnt: root.glyphBurnt
  }

  // ---- UI-facing IPC verbs --------------------------------------------------
  // open/close/toggle/show/hide act on the bar-widget dropdown. That state
  // (PanelController) is private to the one live Panel.qml instance, so it
  // cannot be serviced directly here — these signals are the forwarding seam
  // Panel.qml connects to (see its Connections block).
  signal openPanelRequested()
  signal closePanelRequested()
  signal togglePanelRequested()

  // Fixed argv, no user input — the exact mechanism Panel.qml's own "Open
  // Stage" button already used before this refactor. Kept as a subprocess
  // call rather than calling shell.toggle() in-process (which this file
  // could now do, since it's the natural place to reach the shell host) so
  // the `stage` verb's externally observable behaviour is unchanged.
  function stage() {
    Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "zzwong.kettle"])
  }

  IpcHandler {
    target: "kettle"

    function open() { root.openPanelRequested() }
    function close() { root.closePanelRequested() }
    function show() { root.openPanelRequested() }
    function hide() { root.closePanelRequested() }
    function toggle() { root.togglePanelRequested() }
    function count(): string { return String(store.liveCount) }
    function stage() { root.stage() }

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
}
