.pragma library

// Shipped descriptors only. Events select an entry, never a command or URL.
var adapters = {
  "codex-desktop": {
    helper: "kettle-codex-jump", instances: ["default"], receipt: "opened",
    thread: /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i
  }
}
var errors = ["unsupported", "owner-conflict", "invalid-target", "app-unavailable",
  "authentication-required", "thread-unavailable", "window-ambiguous",
  "transport-failed", "timeout", "busy", "cancelled"]

function object(value) { return value && typeof value === "object" && !Array.isArray(value) }
function fields(value, allowed) {
  return Object.keys(value).every(function(k) { return allowed.indexOf(k) >= 0 })
}
function bytes(value) { return unescape(encodeURIComponent(value)).length }
function address(value) {
  return typeof value === "string" && /^0x[0-9a-f]{1,16}$/i.test(value) ? value.toLowerCase() : ""
}
function descriptor(app, registry) {
  registry = registry || adapters
  return Object.prototype.hasOwnProperty.call(registry, app) ? registry[app] : null
}
function scope(raw) {
  if (!object(raw) || typeof raw.app !== "string" || typeof raw.instance !== "string") return ""
  if (!/^[a-z][a-z0-9-]{0,47}$/.test(raw.app)
      || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(raw.instance)) return ""
  return raw.app + ":" + raw.instance + ":"
}
function validate(raw, registry) {
  if (!object(raw) || !fields(raw, ["version", "kind", "app", "instance", "threadId"])
      || raw.version !== 1 || raw.kind !== "desktop-chat" || !scope(raw)
      || typeof raw.threadId !== "string"
      || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(raw.threadId)
      || raw.threadId.indexOf("..") >= 0)
    return { target: null, error: "invalid-target" }
  var adapter = descriptor(raw.app, registry)
  if (!adapter || adapter.instances.indexOf(raw.instance) < 0)
    return { target: null, error: "unsupported" }
  // Grammar belongs to the owner, not the provider executing its work.
  if (!adapter.thread.test(raw.threadId)) return { target: null, error: "invalid-target" }
  return { target: { version: 1, kind: "desktop-chat", app: raw.app,
    instance: raw.instance, threadId: raw.threadId }, error: "" }
}
function same(a, b) {
  return !!a && !!b && a.app === b.app && a.instance === b.instance && a.threadId === b.threadId
}
function normalize(ev, registry) {
  // Relay also strips these fields. Defense in depth for local IPC with host.
  if (ev.host) return { target: null, error: "", desktop: false, scope: "" }
  var legacy = null, legacyPresent = !!ev.desktopThread
  if (legacyPresent && ev.agent === "codex" && ev.desktopThread === ev.id) {
    legacy = validate({ version: 1, kind: "desktop-chat", app: "codex-desktop",
      instance: "default", threadId: ev.desktopThread }, registry).target
  }
  var present = ev.navigation !== undefined
  var result = present ? validate(ev.navigation, registry)
    : { target: legacy, error: legacyPresent && !legacy ? "invalid-target" : "" }
  if (present && legacyPresent && (!legacy || !same(legacy, result.target)))
    result = { target: null, error: "owner-conflict" }
  result.desktop = present || legacyPresent
  // Keep #20 notification keys stable for the default Codex hook mapping.
  var compatible = (present ? ev.navigation : legacy)
  var oldKey = compatible && compatible.app === "codex-desktop"
    && compatible.instance === "default" && compatible.threadId === ev.id && ev.agent === "codex"
  result.scope = present && !oldKey ? scope(ev.navigation) : ""
  return result
}
function key(ev, normalized) {
  return "agent:" + (ev.host ? ev.host + ":" : "")
    + (normalized.scope ? "desktop:" + normalized.scope + encodeURIComponent(String(ev.id)) : ev.id)
}
function request(requestId, target, registry) {
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(requestId)) return null
  var checked = validate(target, registry)
  if (!checked.target) return null
  return { version: 1, requestId: requestId, target: checked.target }
}
function result(text, code, pending, registry) {
  try {
    if (bytes(text) > 4096) return null
    var r = JSON.parse(text)
    if (!object(r) || r.version !== 1 || r.requestId !== pending.requestId) return null
    if (r.ok === false) {
      if (code === 0 || !fields(r, ["version", "requestId", "ok", "code", "message"])
          || errors.indexOf(r.code) < 0 || typeof r.message !== "string"
          || r.message.length > 160 || /[\x00-\x1f\x7f]/.test(r.message)) return null
      return r
    }
    var adapter = descriptor(pending.target.app, registry)
    if (code !== 0 || r.ok !== true || !adapter || !address(r.window)
        || !fields(r, ["version", "requestId", "ok", "resolution", "window", "selectedThreadId", "instance"])) return null
    if (r.resolution === "selected") {
      if (r.selectedThreadId !== pending.target.threadId
          || (r.instance !== undefined && r.instance !== pending.target.instance)) return null
    } else if (r.resolution !== "opened" || adapter.receipt !== "opened"
        || r.selectedThreadId !== undefined || r.instance !== undefined) return null
    r.window = address(r.window)
    return r
  } catch (e) { return null }
}
function message(code) {
  var messages = {
    "unsupported": "This desktop app or instance is not supported.",
    "owner-conflict": "Conflicting desktop ownership; keeping this session.",
    "invalid-target": "This session has no valid navigation target.",
    "app-unavailable": "Desktop app or URL handler unavailable. Retry after opening it.",
    "authentication-required": "Sign in to the desktop app, then retry.",
    "thread-unavailable": "The desktop conversation is unavailable.",
    "window-ambiguous": "Cannot identify the desktop window. Activate it, then retry.",
    "transport-failed": "Could not open or focus the conversation. Retry.",
    "timeout": "Desktop navigation timed out. Retry.",
    "busy": "Another desktop jump is still running. Retry shortly.",
    "cancelled": "Desktop navigation cancelled; session kept."
  }
  return messages[code] || messages["transport-failed"]
}
