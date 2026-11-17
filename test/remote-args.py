#!/usr/bin/env python3
"""Exact install argv prefix only; never execute setup, SSH or configuration work."""
import os
from pathlib import Path
import subprocess
import sys
import unittest

source = Path(sys.argv.pop(1)).read_text()
start = source.index("cmd_install() {")
end = source.index("  [[ -x $HOOK ]]", start)
prefix = source[start:end]
session_rule = next(line for line in source.splitlines() if line.startswith("SESSION_RE="))
assert "ensure_local" not in prefix and "ssh " not in prefix
program = ('set -uo pipefail\n' + session_rule + '\n' + 'die() { printf "%s\\n" "$*" >&2; exit 1; }\n' + prefix +
           'printf "%s\\0%s\\0%s\\0" "$host" "$session" "$session_given";\n}\n' +
           'cmd_install "$@"\n')


class RemoteArguments(unittest.TestCase):
    def parse(self, args):
        return subprocess.run(["bash", "-s", "--", *args], input=program,
                              capture_output=True, text=True, timeout=2,
                              env={"PATH": os.defpath, "LC_ALL": "C", "BASH_ENV": ""})

    def accepted(self, args, session, given):
        result = self.parse(args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(result.stdout.split("\0"), ["synthetic-host", session, str(given), ""])

    def test_absent_session_value_is_rejected(self):
        for prefix in (["synthetic-host"], ["synthetic-host", "--session", "earlier"]):
            with self.subTest(prefix=prefix):
                result = self.parse([*prefix, "--session"])
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr, "--session requires a value\n")

    def test_omitted_flag_remains_not_given(self):
        self.accepted(["synthetic-host"], "", 0)

    def test_both_explicit_empty_forms_and_no_session_remain_clear(self):
        for args in (["--session", ""], ["--session="], ["--no-session"]):
            with self.subTest(args=args):
                self.accepted(["synthetic-host", *args], "", 1)

    def test_named_session_forms_and_ordering(self):
        for args in (["synthetic-host", "--session", "named_1"],
                     ["--session", "named_1", "synthetic-host"],
                     ["synthetic-host", "--session=named_1"]):
            with self.subTest(args=args):
                self.accepted(args, "named_1", 1)

    def test_repeated_options_preserve_last_value(self):
        self.accepted(["synthetic-host", "--session", "first", "--session", "last"], "last", 1)
        self.accepted(["synthetic-host", "--session", "first", "--no-session"], "", 1)

    def test_invalid_and_unknown_inputs_stay_rejected(self):
        for args in (["synthetic-host", "--session", "bad/name"],
                     ["synthetic-host", "--unknown"], [], ["one", "two"]):
            with self.subTest(args=args):
                result = self.parse(args)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
