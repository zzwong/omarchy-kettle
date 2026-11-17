#!/usr/bin/env python3
"""Real argument prefixes only; exclude filesystem, SSH and relay operations."""
import os
from pathlib import Path
import subprocess
import sys
import unittest

source = Path(sys.argv.pop(1)).read_text()
session_rule = next(line for line in source.splitlines() if line.startswith("SESSION_RE="))
END = {"install": "  [[ -x $HOOK ]]", "test": "  [[ -f $TOKENS/$host ]]",
       "status": "  local port;", "uninstall": "  # Delete the token first:"}


def program(command):
    start = source.index(f"cmd_{command}() {{")
    prefix = source[start:source.index(END[command], start)]
    assert not any(text in prefix for text in ("ensure_local", "ssh ", "rm ", "sed "))
    return ('set -uo pipefail\n' + session_rule + '\n' +
            'die() { printf "%s\\n" "$*" >&2; exit 1; }\n' + prefix +
            'printf "%s\\0" "$host";\n}\n' + f'cmd_{command} "$@"\n')


class HostArguments(unittest.TestCase):
    def parse(self, command, args):
        return subprocess.run(["bash", "-s", "--", *args], input=program(command),
                              capture_output=True, text=True, timeout=2,
                              env={"PATH": os.defpath, "LC_ALL": "C", "BASH_ENV": ""})

    def test_relay_compatible_host_keys_remain_accepted(self):
        for command in END:
            for host in ("ci-linux-01", "box.local", "1", "ssh_alias-1", "a" * 253):
                with self.subTest(command=command, host=host):
                    result = self.parse(command, [host])
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stderr, "")
                    self.assertEqual(result.stdout, host + "\0")

    def test_outside_or_unsupported_keys_are_refused_before_effects(self):
        for command in END:
            for host in ("../relay.conf", "../../outside", ".", "..", "/absolute", "a/b",
                         "-oProxyCommand=x", "user@host", "ssh://host", "a:b",
                         "host\nextra", "host\textra", "a" * 254):
                with self.subTest(command=command, host=repr(host)):
                    result = self.parse(command, [host])
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(result.stdout, "")

    def test_optional_status_host_remains_optional(self):
        result = self.parse("status", [])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "\0")

    def test_other_commands_still_require_a_host(self):
        for command in ("install", "test", "uninstall"):
            with self.subTest(command=command):
                result = self.parse(command, [])
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
