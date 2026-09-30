import QtQuick
import Quickshell
import Quickshell.Io
import "Navigation.js" as Navigation

QtObject {
  id: root
  property PotStore store: PotStore {}
  property int checks: 0
  function check(condition, label) {
    if (!condition) throw new Error(label)
    checks++
  }
  function target(app, thread, instance) {
    return {version: 1, kind: "desktop-chat", app: app,
      instance: instance || "default", threadId: thread}
  }
  Component.onCompleted: {
    try {
      var uuid = "11111111-1111-4111-8111-111111111111"
      var production = target("codex-desktop", uuid)
      // Test-only descriptors prove owner IDs need not share a grammar or
      // receipt policy. Neither is registered in the shipped application.
      var fixtures = {
        "test-open": {helper: "not-executable", instances: ["default", "nightly"],
          thread: /^task_[a-z0-9]+$/, receipt: "opened"},
        "test-select": {helper: "not-executable", instances: ["default"],
          thread: /^[0-9]{1,8}$/, receipt: "selected"}
      }
      check(!!Navigation.validate(production).target, "production target")
      check(!Navigation.validate(target("test-open", "task_a")).target, "test descriptor not shipped")
      check(!!Navigation.validate(target("test-open", "task_a", "nightly"), fixtures).target, "non-UUID grammar and instance")
      check(!!Navigation.validate(target("test-select", "42"), fixtures).target, "numeric owner ID")
      check(!Navigation.validate(target("test-select", "task_a"), fixtures).target, "per-owner grammar")
      check(!Navigation.validate(target("__proto__", uuid)).target, "prototype not an adapter")
      check(!Navigation.validate(target("codex-desktop", uuid + "?x=1")).target, "URL suffix")
      check(!Navigation.validate(target("codex-desktop", uuid, "nightly")).target, "unconfigured instance")
      var raw = Object.assign({}, production, {command: "evil"})
      check(!Navigation.validate(raw).target, "extra routing fields")
      raw = Object.assign({}, production, {version: true})
      check(!Navigation.validate(raw).target, "version type")
      var ev = {id: uuid, agent: "codex", desktopThread: uuid, navigation: production}
      check(Navigation.key(ev, Navigation.normalize(ev)) === "agent:" + uuid, "legacy notification key")
      check(Navigation.normalize(Object.assign({}, ev, {navigation: target("codex-desktop",
        "11111111-1111-4111-8111-111111111112")})).error === "owner-conflict", "conflicting mapping")
      check(!Navigation.normalize(Object.assign({}, ev, {host: "remote"})).desktop, "remote desktop stripped")
      var first = {id: "same-provider", agent: "codex", navigation: target("test-open", "task_a"), state: "finished"}
      var second = Object.assign({}, first, {navigation: target("test-open", "task_a", "nightly")})
      var third = Object.assign({}, first, {navigation: target("test-select", "42")})
      check(Navigation.key(first, Navigation.normalize(first, fixtures)) !== Navigation.key(second, Navigation.normalize(second, fixtures)), "instance isolation")
      check(Navigation.key(first, Navigation.normalize(first, fixtures)) !== Navigation.key(third, Navigation.normalize(third, fixtures)), "owner isolation")
      // Unknown/invalid metadata must not turn a lifecycle event into a lost
      // completion or a terminal fallback that could dismiss the wrong chat.
      store.ingest(Object.assign({}, first, {window: "0x1234", focused: true}))
      var informational = store.hookList()[0]
      check(informational.state === "ready" && !informational.windowAddr
        && informational.navigationError === "unsupported", "informational unknown owner")
      store.seenWindow("0x1234")
      check(store.hookList().length === 1, "unknown owner survives focus")
      store.ingest({id: uuid, agent: "codex", state: "finished", navigation: production})
      var original = store.hookPots["agent:" + uuid]
      store.ingest({id: uuid, agent: "codex", state: "finished", navigation: production})
      check(store.hookPots[original.key].revision > original.revision, "repeated event revision")
      store.acknowledgeHookPot(original)
      check(!!store.hookPots[original.key], "repeated completion survives old receipt")
      original = store.hookPots[original.key]
      store.dropHookPot(original.key)
      store.ingest({id: uuid, agent: "codex", state: "finished", navigation: production})
      store.acknowledgeHookPot(original)
      check(!!store.hookPots[original.key], "recreated pot survives old receipt")
      var req = Navigation.request("test", target("test-open", "task_a"), fixtures)
      var receipt = {version: 1, requestId: "test", ok: true, resolution: "opened", window: "0x1234"}
      check(!!Navigation.result(JSON.stringify(receipt), 0, req, fixtures), "opened policy")
      check(!Navigation.result(JSON.stringify(receipt), 1, req, fixtures), "stdout does not override nonzero exit")
      check(!Navigation.result(JSON.stringify(Object.assign({}, receipt, {requestId: "old"})), 0, req, fixtures), "request correlation")
      check(!Navigation.result(JSON.stringify(Object.assign({}, receipt, {window: '0x1"; evil'})), 0, req, fixtures), "address validation")
      check(!Navigation.result(JSON.stringify(Object.assign({}, receipt, {command: "evil"})), 0, req, fixtures), "receipt routing field")
      check(!Navigation.result(JSON.stringify(receipt) + JSON.stringify(receipt), 0, req, fixtures), "single receipt")
      check(!Navigation.result("x".repeat(4097), 0, req, fixtures), "receipt byte cap")
      req = Navigation.request("select", target("test-select", "42"), fixtures)
      receipt.requestId = "select"
      check(!Navigation.result(JSON.stringify(receipt), 0, req, fixtures), "selected policy cannot degrade")
      receipt.resolution = "selected"
      receipt.selectedThreadId = "42"
      check(!!Navigation.result(JSON.stringify(receipt), 0, req, fixtures), "selection receipt")
      receipt.selectedThreadId = "43"
      check(!Navigation.result(JSON.stringify(receipt), 0, req, fixtures), "selection ID mismatch")
      receipt.selectedThreadId = "42"
      receipt.instance = "nightly"
      check(!Navigation.result(JSON.stringify(receipt), 0, req, fixtures), "selection instance mismatch")
      var failure = {version: 1, requestId: "select", ok: false, code: "timeout", message: "Retry."}
      check(!!Navigation.result(JSON.stringify(failure), 1, req, fixtures), "typed failure")
      check(!Navigation.result(JSON.stringify(failure), 0, req, fixtures), "failure cannot exit zero")
      console.log("CONTRACT:PASS:" + checks)
    } catch (e) { console.log("CONTRACT:FAIL:" + e) }
    killer.running = true
  }
  property Process killer: Process { command: ["kill", "-9", String(Quickshell.processId)] }
}
