#!/bin/bash
# Remote-side herdr watcher. Passed to ssh as the command string — never
# installed on the remote, so "nothing installed" stays literally true and
# there is no version skew between a pushed script and the plugin.
#
# Emits one line per event:
#   S <base64-json>    normalized snapshot projection, only when it changes
#   H                  heartbeat, so silence is distinguishable from death
#   D                  herdr is down / unreadable
#
# THE ORPHAN RULE — the load-bearing line in this file.
#
# With no pty, sshd does not reliably signal this command when the ssh channel
# closes. It only learns it is orphaned by writing to a dead pipe. A loop that
# emits nothing while state is quiet would therefore never notice and would run
# forever, spawning `herdr api snapshot` every few seconds until the machine
# reboots — one leaked loop per reload.
#
# Two things prevent that, and both are required:
#   1. the heartbeat guarantees a write every HEARTBEAT seconds, bounding
#      orphan lifetime to one interval;
#   2. every emit uses the `printf` BUILTIN with `|| exit 0`. If emit were an
#      external process, SIGPIPE would kill that child while this loop carried
#      on — an immortal orphan. The builtin makes the write failure ours.

set -uo pipefail

# Absolute path injected by the caller. A bare `herdr` would resolve against a
# non-interactive PATH that usually lacks ~/.local/bin, and the failure would
# look identical to "herdr is down".
HERDR=${KETTLE_HERDR:-herdr}

INTERVAL=${KETTLE_INTERVAL:-2}
HEARTBEAT=${KETTLE_HEARTBEAT:-30}

emit() { printf '%s\n' "$1" || exit 0; }

prev=""
last_beat=$SECONDS

while :; do
  raw=$("$HERDR" api snapshot 2>/dev/null)

  if [[ -z $raw ]]; then
    # Distinguish "herdr is gone" from "nothing changed". Hashing the error
    # output would emit one garbage change and then fall silent, stranding
    # stale pots on the bar forever.
    [[ $prev != "DOWN" ]] && { emit "D"; prev="DOWN"; }
  else
    # Project before hashing: only the fields the bar renders. A future herdr
    # that adds a timestamp or activity counter would otherwise churn the hash
    # every tick and silently degrade this into per-poll.
    proj=$(printf '%s' "$raw" | python3 -c '
import base64, json, sys
try:
    snap = json.load(sys.stdin)["result"]["snapshot"]
except Exception:
    sys.exit(1)
agents = []
for a in snap.get("agents") or []:
    agents.append({
        "id":     a.get("pane_id") or "",
        "agent":  a.get("agent") or "",
        "state":  a.get("agent_status") or "",
        "cwd":    a.get("cwd") or "",
        "title":  a.get("terminal_title_stripped") or "",
        "name":   a.get("name") or "",
        "seq":    a.get("state_change_seq"),
    })
agents.sort(key=lambda x: x["id"])
out = {"agents": agents, "focused": snap.get("focused_pane_id") or ""}
sys.stdout.write(base64.b64encode(
    json.dumps(out, sort_keys=True, separators=(",", ":")).encode()).decode())
' 2>/dev/null)

    if [[ -z $proj ]]; then
      [[ $prev != "DOWN" ]] && { emit "D"; prev="DOWN"; }
    elif [[ $proj != "$prev" ]]; then
      emit "S $proj"
      prev=$proj
    fi
  fi

  if (( SECONDS - last_beat >= HEARTBEAT )); then
    emit "H"
    last_beat=$SECONDS
  fi

  sleep "$INTERVAL"
done
