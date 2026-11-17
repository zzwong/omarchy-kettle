"""Shared helper contract and bounded, click-time compositor operations."""

import json
import os
import re
import selectors
import signal
import subprocess
import time


class NavigationError(Exception):
    def __init__(self, code):
        self.code = code


def fullmatch(pattern, value):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def request(raw, app, grammar, instances=("default",)):
    if len(raw.encode("utf-8")) > 2048:
        raise NavigationError("invalid-target")
    try:
        value = json.loads(raw)
        if not isinstance(value, dict) or set(value) != {"version", "requestId", "target"}:
            raise ValueError()
        target = value["target"]
        if (type(value["version"]) is not int or value["version"] != 1
                or not fullmatch(r"[A-Za-z0-9_-]{1,64}", value["requestId"])
                or not isinstance(target, dict)
                or set(target) != {"version", "kind", "app", "instance", "threadId"}
                or type(target["version"]) is not int or target["version"] != 1
                or target["kind"] != "desktop-chat" or target["app"] != app
                or target["instance"] not in instances
                or not fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}", target["threadId"])
                or ".." in target["threadId"]
                or not fullmatch(grammar, target["threadId"])
                or len(target["threadId"]) > 128):
            raise ValueError()
        return value
    except (ValueError, TypeError, KeyError):
        raise NavigationError("invalid-target") from None


class Runner:
    """One monotonic budget; terminate only direct integration-owned children."""

    def __init__(self):
        self.deadline = time.monotonic() + 9.5
        self.reads = 0
        self.child = None
        self.cursor = None

    def remaining(self):
        seconds = self.deadline - time.monotonic()
        if seconds <= 0:
            raise NavigationError("timeout")
        return seconds

    def cancel(self, *_):
        if self.child and self.child.poll() is None:
            self.child.terminate()
        raise NavigationError("cancelled")

    def command(self, argv, cap=262144, limit=2):
        self.remaining()
        end = min(self.deadline, time.monotonic() + limit)
        try:
            # Bound every transport pipe and discard private error context.
            self.child = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            with selectors.DefaultSelector() as selector:
                selector.register(self.child.stdout, selectors.EVENT_READ)
                data = bytearray()
                while selector.get_map():
                    remaining = end - time.monotonic()
                    if remaining <= 0:
                        raise NavigationError("timeout")
                    for key, _ in selector.select(remaining):
                        chunk = os.read(key.fd, 4096)
                        if not chunk:
                            selector.unregister(key.fileobj)
                        else:
                            data.extend(chunk)
                            if len(data) > cap:
                                raise NavigationError("transport-failed")
                remaining = end - time.monotonic()
                if remaining <= 0:
                    raise NavigationError("timeout")
                if self.child.wait(timeout=remaining) != 0:
                    raise NavigationError("transport-failed")
                return bytes(data).decode("utf-8")
        except FileNotFoundError:
            raise NavigationError("app-unavailable") from None
        except (OSError, UnicodeError):
            raise NavigationError("transport-failed") from None
        except subprocess.TimeoutExpired:
            raise NavigationError("timeout") from None
        finally:
            if self.child:
                if self.child.poll() is None:
                    self.child.terminate()
                    try:
                        self.child.wait(timeout=0.1)
                    except subprocess.TimeoutExpired:
                        self.child.kill()
                        self.child.wait(timeout=0.1)
                self.child.stdout.close()
                self.child = None

    def compositor(self, name):
        self.reads += 1
        if self.reads > 40:
            raise NavigationError("timeout")
        try:
            return json.loads(self.command(["hyprctl", name, "-j"]))
        except ValueError:
            raise NavigationError("transport-failed") from None

    def pause(self):
        time.sleep(min(0.05, self.remaining()))

    def focus(self, address, classes):
        # Recheck identity before dispatch, then require active-window evidence.
        clients = self.compositor("clients")
        if not any(isinstance(c, dict) and c.get("address") == address
                   and str(c.get("class", "")).lower() in classes for c in clients):
            raise NavigationError("app-unavailable")
        cursor = self.cursor if self.cursor is not None else self.compositor("cursorpos")
        if not isinstance(cursor, dict) or any(type(cursor.get(k)) is not int
                or abs(cursor[k]) > 1000000 for k in ("x", "y")):
            raise NavigationError("transport-failed")
        batch = 'dispatch hl.dsp.focus({ window = "address:' + address + '" })'
        batch += ' ; dispatch hl.dsp.cursor.move({ x = ' + str(cursor["x"])
        batch += ', y = ' + str(cursor["y"]) + ' })'
        self.command(["hyprctl", "--batch", batch], cap=4096)
        for _ in range(5):
            active = self.compositor("activewindow")
            if (isinstance(active, dict) and active.get("address") == address
                    and str(active.get("class", "")).lower() in classes):
                return
            self.pause()
        raise NavigationError("transport-failed")


def receipt(request_id, **fields):
    print(json.dumps({"version": 1, "requestId": request_id, **fields}, separators=(",", ":")))


def serve(argv, app, grammar, open_chat):
    request_id = "invalid"
    runner = Runner()
    signal.signal(signal.SIGTERM, runner.cancel)
    signal.signal(signal.SIGINT, runner.cancel)
    try:
        if len(argv) != 2:
            raise NavigationError("invalid-target")
        parsed = request(argv[1], app, grammar)
        request_id = parsed["requestId"]
        # URL activation itself may warp the pointer before focus runs.
        runner.cursor = runner.compositor("cursorpos")
        address = open_chat(runner, parsed["target"])
        receipt(request_id, ok=True, resolution="opened", window=address)
        return 0
    except NavigationError as error:
        # Fixed messages only; exception text can include private context.
        receipt(request_id, ok=False, code=error.code, message="Desktop navigation failed; session kept.")
        return 1
    except (ValueError, TypeError, KeyError, AttributeError):
        receipt(request_id, ok=False, code="transport-failed", message="Invalid desktop transport response.")
        return 1
