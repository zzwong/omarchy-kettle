import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
  id: root
  property PotStore pots: PotStore {}
  property Navigator nav: Navigator { pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, ""); store: root.pots }
  property int stage: 0
  property int checks: 0
  property int elapsed: 0
  property var original: null
  property string a: "11111111-1111-4111-8111-111111111111"
  property string b: "11111111-1111-4111-8111-111111111112"
  function check(condition, label) { if (!condition) throw new Error(label); checks++ }
  function emit(id, state) { pots.ingest({id: id, agent: "codex", state: state, desktopThread: id}) }
  function owned(app, instance, thread) {
    pots.ingest({id: "provider_shared", agent: "codex", state: "finished", navigation: {
      version: 1, kind: "desktop-chat", app: app, instance: instance, threadId: thread}})
    return pots.hookPots["agent:desktop:" + app + ":" + instance + ":provider_shared"]
  }
  function pot(id) { return pots.hookPots["agent:" + id] }
  function mode(value) { nav.jumper.environment = {KETTLE_TEST_MODE: value} }
  function finish(error) {
    console.log(error ? "CONTROLLER:FAIL:" + error : "CONTROLLER:PASS:" + checks)
    ticker.stop()
    nav.cancel()
    killer.running = true
  }
  Component.onCompleted: {
    emit(a, "finished"); emit(b, "finished")
    mode("success")
    nav.start(pot(a))
    nav.start(pot(a))
    check(nav.serial === 1, "same target coalesces")
    nav.start(pot(b))
    check(nav.serial === 1 && nav.outcome.indexOf("still running") >= 0, "different target busy")
  }
  property Timer ticker: Timer {
    interval: 50; running: true; repeat: true
    onTriggered: {
      try {
        if (++root.elapsed > 160) throw new Error("harness timeout")
        if (nav.busy) return
        switch (root.stage++) {
          case 0:
            check(!pot(a) && !!pot(b), "success acknowledges only selected finished pot")
            emit(a, "finished"); mode("nonzero"); nav.start(pot(a)); break
          case 1:
            check(!!pot(a) && nav.outcome.length > 0, "nonzero exit with success stdout keeps pot")
            mode("mismatch"); nav.start(pot(a)); break
          case 2:
            check(!!pot(a), "mismatched receipt keeps pot")
            mode("malformed"); nav.start(pot(a)); break
          case 3:
            check(!!pot(a), "malformed receipt keeps pot")
            mode("success"); nav.start(pot(a)); emit(a, "finished"); break
          case 4:
            check(!!pot(a), "same-state revision survives late receipt")
            nav.start(pot(a)); emit(a, "working"); break
          case 5:
            check(pot(a).state === "simmering", "live work survives receipt")
            emit(a, "finished"); nav.start(pot(a)); pots.dropHookPot(pot(a).key); emit(a, "finished"); break
          case 6:
            check(!!pot(a) && nav.outcome.indexOf("cancelled") >= 0, "removal cancels and recreated pot survives receipt")
            mode("slow"); nav.start(pot(a)); nav.deadline.interval = 100; break
          case 7:
            check(!!pot(a) && nav.outcome.indexOf("timed out") >= 0, "timeout retains pot")
            // Wait for the cancelled process to exit before retrying.
            break
          case 8:
            mode("success"); nav.deadline.interval = 10000; nav.start(pot(a)); break
          case 9:
            check(!pot(a), "retry succeeds after cancellation")
            emit(a, "finished"); mode("oversized"); nav.start(pot(a)); break
          case 10:
            check(!!pot(a), "oversized stdout keeps pot")
            break
          case 11:
            finish(); break
        }
      } catch (e) { finish(e) }
    }
  }
  property Process killer: Process { command: ["kill", "-9", String(Quickshell.processId)] }
}
