#!/usr/bin/env python3
"""Exercise the real guard with deterministic reads and no remote process."""
import io
import runpy
import sys
from unittest.mock import patch

guard = runpy.run_path(sys.argv[1])


class Input:
    def __init__(self, chunks):
        self.chunks = iter(chunks)

    def read1(self, limit):
        chunk = next(self.chunks, b"")
        assert len(chunk) <= limit
        return chunk


class Wrapped:
    def __init__(self, buffer):
        self.buffer = buffer


def check(chunks, code, output):
    target = io.BytesIO()
    errors = io.StringIO()
    with patch.object(sys, "stdin", Wrapped(Input(chunks))), \
            patch.object(sys, "stdout", Wrapped(target)), \
            patch.object(sys, "stderr", errors):
        actual = guard["main"]()
    assert actual == code, (actual, code)
    assert target.getvalue() == output
    assert ("exceeded" in errors.getvalue()) == (code == 1)


full = [b"x" * 8192] * 8
check(full + [b"\n"], 0, b"x" * 65536 + b"\n")
check(full + [b"x\n"], 1, b"")
check(full + [b"x", b"\n"], 1, b"")
check(full + [b"x"], 1, b"")
check(full + [b"\nok\n"], 0, b"x" * 65536 + b"\nok\n")
check(full + [b"x\nok\n"], 1, b"")
check([b"ok\n"] + full + [b"x\n"], 1, b"ok\n")
check([b"hel", b"lo\n"], 0, b"hello\n")
check([b"partial"], 0, b"")


class ClosedPipe:
    def write(self, data):
        raise BrokenPipeError()


with patch.object(sys, "stdin", Wrapped(Input([b"ok\n"]))), \
        patch.object(sys, "stdout", Wrapped(ClosedPipe())):
    assert guard["main"]() == 0
print("10 deterministic line-guard cases passed")
