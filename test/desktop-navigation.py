#!/usr/bin/env python3
"""Exercise the real desktop opener with stubbed URL and compositor commands."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

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
            "hyprctl": 'import os,sys\nprint(os.environ["KETTLE_NAV_CLIENTS" if sys.argv[1]=="clients" else "KETTLE_NAV_ACTIVE"])\n',
        }.items():
            p = self.path / name
            p.write_text("#!/usr/bin/env python3\n" + body)
            p.chmod(0o755)
        self.clients([{"class": "chatgpt", "address": "0x1234"}])

    def clients(self, clients, active=""):
        self.env["KETTLE_NAV_CLIENTS"] = json.dumps(clients)
        self.env["KETTLE_NAV_ACTIVE"] = json.dumps({"address": active})

    def run_opener(self, thread=THREAD):
        return subprocess.run(
            [str(ROOT / "bin/kettle-codex-jump"), thread], env=self.env,
            capture_output=True, text=True, timeout=10,
        )

    def test_opens_thread_and_returns_app_window(self):
        result = self.run_opener()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "0x1234")
        self.assertEqual((self.path / "url").read_text(), "codex://threads/" + THREAD)

    def test_codex_class(self):
        self.clients([{"class": "Codex", "address": "0xabc"}])
        self.assertEqual(self.run_opener().stdout.strip(), "0xabc")

    def test_rejects_ids_before_opening_anything(self):
        for thread in ["../etc", THREAD + "?host=evil", "$(touch /tmp/no)", "a" * 1000]:
            with self.subTest(thread=thread):
                result = self.run_opener(thread)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertFalse((self.path / "url").exists())

    def test_opener_failure_produces_no_acknowledgment(self):
        self.env["KETTLE_NAV_EXIT"] = "1"
        result = self.run_opener()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_title_alone_does_not_identify_app(self):
        self.clients([{"class": "chromium", "title": "ChatGPT", "address": "0xabc"}])
        result = self.run_opener()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_multiple_windows_use_active_app_window(self):
        self.clients([
            {"class": "chatgpt", "address": "0x1234"},
            {"class": "chatgpt", "address": "0x5678"},
        ], active="0x5678")
        self.assertEqual(self.run_opener().stdout.strip(), "0x5678")

    def test_multiple_inactive_windows_are_not_guessed(self):
        self.clients([
            {"class": "chatgpt", "address": "0x1234"},
            {"class": "chatgpt", "address": "0x5678"},
        ], active="0xbeef")
        result = self.run_opener()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_rejects_malformed_compositor_address(self):
        self.clients([{"class": "chatgpt", "address": '0x1" }); evil'}])
        result = self.run_opener()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
