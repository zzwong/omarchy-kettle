#!/usr/bin/env python3
"""Exercise only emit's argv and dry-run payload; never contact a real shell."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

EMIT = str(Path(sys.argv.pop(1)).resolve())
OPTIONS = ("--agent", "--id", "--state", "--cwd", "--model", "--message", "--window")
VALID = ["--dry-run", "--agent", "synthetic", "--id", "s1", "--state", "working"]


class EmitArguments(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.calls = root / "transport-calls"
        stub = root / "omarchy-shell"
        stub.write_text('#!/bin/bash\nprintf called >> "$KETTLE_TEST_CALLS"\nexit 99\n')
        stub.chmod(0o755)
        self.env = dict(os.environ, HOME=str(root), XDG_CONFIG_HOME=str(root),
                        PATH=f"{root}:{os.environ['PATH']}", KETTLE_TEST_CALLS=str(self.calls))

    def run_emit(self, args):
        result = subprocess.run(["bash", EMIT, *args], env=self.env,
                                capture_output=True, text=True, timeout=1)
        self.assertFalse(self.calls.exists(), "parser test reached transport")
        return result

    def test_each_missing_value_is_rejected(self):
        for prefix in ([], VALID):
            for option in OPTIONS:
                with self.subTest(prefix=bool(prefix), option=option):
                    result = self.run_emit([*prefix, option])
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(result.stdout, "")
                    self.assertEqual(result.stderr, f"kettle-emit: {option} requires a value\n")

    def test_all_values_reach_payload(self):
        result = self.run_emit([*VALID, "--cwd", "/synthetic", "--model", "model-x",
                                "--message", "hello", "--window", "0x123", "--focused"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), dict(source="agent", agent="synthetic",
            id="s1", state="working", cwd="/synthetic", model="model-x", message="hello",
            window="0x123", focused=True))

    def test_repeated_value_last_wins(self):
        result = self.run_emit([*VALID, "--agent", "replacement", "--message", "old",
                                "--message", "new"])
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual((payload["agent"], payload["message"]), ("replacement", "new"))

    def test_empty_optional_values_still_allowed(self):
        result = self.run_emit([*VALID, "--cwd", "", "--model", "", "--message", "", "--window", ""])
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(all(payload[key] == "" for key in ("cwd", "model", "message", "window")))

    def test_dash_prefixed_value_is_still_a_value(self):
        result = self.run_emit([*VALID, "--message", "--focused"])
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["message"], "--focused")
        self.assertIs(payload["focused"], False)

    def test_unknown_and_end_marker_stay_rejected(self):
        for option in ("--unknown", "--"):
            with self.subTest(option=option):
                result = self.run_emit([*VALID, option])
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"kettle-emit: unknown option {option}\n", result.stderr)


if __name__ == "__main__":
    unittest.main()
