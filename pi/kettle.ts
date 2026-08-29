// Kettle pot reporting for pi.
//
// pi is the one first-class agent here with no hook config to install into —
// it has an extension API instead, so `kettle-install` registers this file's
// path in pi's settings.json the way it writes the hook's path into Claude's
// and Codex's. Inside herdr, pi was already visible because herdr detects the
// TUI and Kettle polls herdr; a bare `pi` in a terminal reported nothing,
// which is the most ordinary way to run it.
//
// This does not reimplement the hook. It shells out to kettle-agent-hook with
// the same stdin payload the Claude and Codex hooks send, so window identity
// (the OSC 2 title nonce), the state directory, and the remote ssh relay all
// come along unchanged. The hook writes its nonce to the tty rather than
// stdout, so it cannot corrupt pi's TUI.

import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// Resolved from this file rather than baked in at install time, so
// `omarchy plugin update` moves the hook and the extension together.
const HOOK = resolve(dirname(fileURLToPath(import.meta.url)), "..", "bin", "kettle-agent-hook");

// The hook keys its state file and title nonce on the session id, so it has to
// be stable for the life of the session and safe as a filename. pi's session
// file is both; an ephemeral session (no file yet) falls back to the pid,
// which is stable for the same lifetime.
function sessionId(ctx: any): string {
  const file: string | undefined = ctx?.sessionManager?.getSessionFile?.() ?? undefined;
  const base = file ? file.split("/").pop() ?? "" : "";
  const id = base.replace(/\.[^.]+$/, "");
  return id || `pi-${process.pid}`;
}

// pi names the model as a slug ("deepseek-v4-flash"); Kettle resolves it to a
// display name through the same catalogs it already reads for Codex and pi
// transcripts, so passing the slug through is correct.
function modelSlug(ctx: any): string {
  const m = ctx?.model;
  return (m && (m.id ?? m.modelId ?? m.model)) || "";
}

export default function (pi: ExtensionAPI) {
  // Fire-and-forget: the hook double-backgrounds its own delivery and exits
  // immediately, so a turn is never waiting on Kettle. A failure here must
  // stay invisible — a status widget is not worth interrupting a session for.
  const emit = async (event: string, ctx: any, extra: Record<string, string> = {}) => {
    try {
      const payload = JSON.stringify({
        hook_event_name: event,
        session_id: sessionId(ctx),
        cwd: ctx?.cwd ?? "",
        agent_type: "pi",
        model: modelSlug(ctx),
        ...extra,
      });
      await pi.exec("bash", ["-c", 'printf %s "$1" | "$0"', HOOK, payload], { timeout: 5000 });
    } catch {
      /* Kettle being unavailable is not a pi problem. */
    }
  };

  pi.on("session_start", async (_e, ctx) => emit("SessionStart", ctx));

  // agent_start, not the `input` event: a prompt handled by a command or an
  // extension never reaches the model, and a pot for work that never began
  // would tick a clock against nothing.
  pi.on("agent_start", async (_e, ctx) => emit("UserPromptSubmit", ctx));

  // agent_settled rather than agent_end — pi may still auto-retry, compact and
  // retry, or pick up a queued follow-up after agent_end, and pi's own docs
  // point status integrations here. Using agent_end would flash a pot to
  // "finished" mid-turn and then walk it back.
  pi.on("agent_settled", async (_e, ctx) => emit("Stop", ctx));

  pi.on("session_shutdown", async (_e, ctx) => emit("SessionEnd", ctx));
}
