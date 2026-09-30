#!/usr/bin/env python3
"""Exercise the real desktop opener with stubbed URL and compositor commands."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
THREAD = "11111111-1111-4111-8111-111111111111"


class DesktopNavigation(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.env = dict(os.environ, PATH=str(self.path) + ":" + os.environ["PATH"])
        self.env.update(KETTLE_NAV_LOG=str(self.path / "url"), KETTLE_NAV_EXIT="0")
        for name, body in {
            "xdg-open": 'import os,sys\nopen(os.environ["KETTLE_NAV_LOG"],"w").write(sys.argv[1])\nsys.exit(int(os.environ["KETTLE_NAV_EXIT"]))\n',
            "hyprctl": 'import os,sys\nif sys.argv[1]=="--batch":\n open(os.environ["KETTLE_NAV_LOG"]+".focus","w").write(sys.argv[2])\n sys.exit(int(os.environ.get("KETTLE_NAV_FOCUS_EXIT","0")))\nprint(os.environ[{"clients":"KETTLE_NAV_CLIENTS","activewindow":"KETTLE_NAV_ACTIVE","cursorpos":"KETTLE_NAV_CURSOR"}[sys.argv[1]]])\n',
        }.items():
            p = self.path / name
            p.write_text("#!/usr/bin/env python3\n" + body)
            p.chmod(0o755)
        self.env["KETTLE_NAV_CURSOR"] = json.dumps({"x": 34, "y": -56})
        self.clients([{"class": "chatgpt", "address": "0x1234"}])

    def clients(self, clients, active=None):
        if active is None: active = clients[0].get("address", "") if clients else ""
        app_class = next((c.get("class", "") for c in clients if c.get("address") == active), "")
        self.env["KETTLE_NAV_CLIENTS"] = json.dumps(clients)
        self.env["KETTLE_NAV_ACTIVE"] = json.dumps({"address": active, "class": app_class})

    def run_opener(self, thread=THREAD, request=None):
        value = request or {"version": 1, "requestId": "test_1", "target": {
            "version": 1, "kind": "desktop-chat", "app": "codex-desktop",
            "instance": "default", "threadId": thread}}
        return subprocess.run(
            [str(ROOT / "bin/kettle-codex-jump"), json.dumps(value)], env=self.env,
            capture_output=True, text=True, timeout=10,
        )

    def test_opens_thread_and_returns_app_window(self):
        result = self.run_opener()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["window"], "0x1234")
        self.assertEqual((self.path / "url").read_text(), "codex://threads/" + THREAD)

    def test_codex_class(self):
        self.clients([{"class": "Codex", "address": "0xabc"}])
        self.assertEqual(json.loads(self.run_opener().stdout)["window"], "0xabc")

    def test_rejects_ids_before_opening_anything(self):
        for thread in ["../etc", THREAD + "?host=evil", "$(touch /tmp/no)", "a" * 1000]:
            with self.subTest(thread=thread):
                result = self.run_opener(thread)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(json.loads(result.stdout)["ok"])
                self.assertFalse((self.path / "url").exists())

    def test_opener_failure_produces_no_acknowledgment(self):
        self.env["KETTLE_NAV_EXIT"] = "1"
        result = self.run_opener()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)["ok"])

    def test_title_alone_does_not_identify_app(self):
        self.clients([{"class": "chromium", "title": "ChatGPT", "address": "0xabc"}])
        result = self.run_opener()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)["ok"])

    def test_multiple_windows_use_active_app_window(self):
        self.clients([
            {"class": "chatgpt", "address": "0x1234"},
            {"class": "chatgpt", "address": "0x5678"},
        ], active="0x5678")
        self.assertEqual(json.loads(self.run_opener().stdout)["window"], "0x5678")

    def test_multiple_inactive_windows_are_not_guessed(self):
        self.clients([
            {"class": "chatgpt", "address": "0x1234"},
            {"class": "chatgpt", "address": "0x5678"},
        ], active="0xbeef")
        result = self.run_opener()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)["ok"])

    def test_rejects_malformed_compositor_address(self):
        self.clients([{"class": "chatgpt", "address": '0x1" }); evil'}])
        result = self.run_opener()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)["ok"])

    def test_receipt_and_cursor_preserving_focus(self):
        result = self.run_opener()
        self.assertEqual(json.loads(result.stdout), {"version": 1, "requestId": "test_1",
            "ok": True, "resolution": "opened", "window": "0x1234"})
        batch = (self.path / "url.focus").read_text()
        self.assertIn('address:0x1234', batch)
        self.assertIn('x = 34, y = -56', batch)

    def test_captures_cursor_before_url_activation(self):
        stub = self.path / "hyprctl"
        stub.write_text(stub.read_text().replace('import os,sys\n',
            'import os,sys\nopen(os.environ["KETTLE_NAV_LOG"]+".order","a").write(sys.argv[1]+"\\n")\n'))
        opener = self.path / "xdg-open"
        opener.write_text(opener.read_text().replace('import os,sys\n',
            'import os,sys\nopen(os.environ["KETTLE_NAV_LOG"]+".order","a").write("open\\n")\n'))
        self.assertEqual(self.run_opener().returncode, 0)
        order = (self.path / "url.order").read_text().splitlines()
        self.assertLess(order.index("cursorpos"), order.index("open"))

    def test_invalid_contract_does_not_call_transport(self):
        baseline = {"version": 1, "requestId": "test_1", "target": {
            "version": 1, "kind": "desktop-chat", "app": "codex-desktop",
            "instance": "default", "threadId": THREAD}}
        for field, value in [("version", True), ("requestId", "x" * 65), ("command", "evil")]:
            invalid = dict(baseline, **{field: value})
            self.assertNotEqual(self.run_opener(request=invalid).returncode, 0)
        for field, value in [("version", True), ("instance", "nightly"), ("app", "__proto__"),
                             ("threadId", "x" * 3000), ("url", "file:///etc/passwd")]:
            invalid = dict(baseline, target=dict(baseline["target"], **{field: value}))
            self.assertNotEqual(self.run_opener(request=invalid).returncode, 0)
        self.assertFalse((self.path / "url").exists())

    def test_failed_focus_keeps_pot(self):
        self.env["KETTLE_NAV_FOCUS_EXIT"] = "1"
        result = self.run_opener()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)["ok"])

    def test_wrong_active_window_is_not_success(self):
        self.clients([{"class": "chatgpt", "address": "0x1234"}], active="0xbeef")
        self.assertNotEqual(self.run_opener().returncode, 0)

    def test_bounded_output_and_monotonic_deadline(self):
        sys.path.insert(0, str(ROOT / "lib"))
        from kettle_navigation import Runner, NavigationError
        runner = Runner()
        with self.assertRaises(NavigationError) as caught:
            runner.command([sys.executable, "-c", 'print("x" * 100000)'], cap=4096)
        self.assertEqual(caught.exception.code, "transport-failed")
        runner.deadline = time.monotonic() + 0.1
        begin = time.monotonic()
        with self.assertRaises(NavigationError) as caught:
            runner.command([sys.executable, "-c", "import time; time.sleep(10)"])
        self.assertEqual(caught.exception.code, "timeout")
        self.assertLess(time.monotonic() - begin, 1)
        self.assertIsNone(runner.child)
        runner = Runner()
        runner.reads = 40
        with self.assertRaises(NavigationError): runner.compositor("clients")


if __name__ == "__main__":
    unittest.main()
