"""Exercise only embedded writers with inert files in owned temp directories."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(sys.argv.pop(1)).read_text()
MARKERS = {
    'merge': '  python3 - "$file" "$mode" "$hook" "$style" "$unit" "$use_async" "$@" <<\'PY\'\n',
    'pi': '  python3 - "$PI_SETTINGS" "$PI_EXTENSION" "$mode" <<\'PY\'\n',
}
BODIES = {}
for name, marker in MARKERS.items():
    assert SOURCE.count(marker) == 1
    start = SOURCE.index(marker) + len(marker)
    BODIES[name] = SOURCE[start:SOURCE.index('\nPY\n', start)] + '\n'

GUARD = '''import sys

def deny(event, args):
    if event.startswith("socket.") or event in ("subprocess.Popen", "os.system", "os.posix_spawn"):
        raise RuntimeError("transport/process operation forbidden")
sys.addaudithook(deny)
exec(compile(sys.stdin.read(), "extracted-installer-writer", "exec"))
'''


class InstallerWriters(unittest.TestCase):
    def run_writer(self, writer, root, mode='install'):
        path = root / 'settings.json'
        args = ([str(path), mode, '/synthetic/kettle-agent-hook', 'wrapped', 's', 'yes', 'Stop']
                if writer == 'merge' else [str(path), '/synthetic/kettle.ts', mode])
        return subprocess.run([sys.executable, '-B', '-c', GUARD, *args], input=BODIES[writer],
                              text=True, capture_output=True, timeout=3,
                              env={'PATH': os.defpath, 'HOME': str(root)})

    def test_preexisting_staging_occupants_and_targets_are_unchanged(self):
        for writer in BODIES:
            for kind in ('file', 'symlink'):
                with self.subTest(writer=writer, kind=kind), tempfile.TemporaryDirectory() as temp:
                    root = Path(temp)
                    path = root / 'settings.json'
                    path.write_text('{"theme":"dark"}\n')
                    path.chmod(0o600)
                    victim = root / 'synthetic-victim.json'
                    sentinel = b'{"synthetic-sentinel":true}\n'
                    victim.write_bytes(sentinel)
                    victim.chmod(0o640)
                    staging = root / 'settings.json.kettle-tmp'
                    if kind == 'symlink':
                        staging.symlink_to(victim.name)
                    else:
                        staging.write_bytes(sentinel)
                        staging.chmod(0o640)
                    before = staging.lstat()
                    result = self.run_writer(writer, root)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(victim.read_bytes(), sentinel)
                    self.assertEqual(victim.stat().st_mode & 0o777, 0o640)
                    self.assertEqual(staging.lstat().st_ino, before.st_ino)
                    self.assertEqual(staging.lstat().st_dev, before.st_dev)
                    self.assertEqual(staging.is_symlink(), kind == 'symlink')
                    self.assertEqual(staging.read_bytes(), sentinel)
                    self.assertFalse(path.is_symlink())
                    self.assertEqual(json.loads(path.read_text())['theme'], 'dark')

    def test_normal_install_remove_preserves_content_modes_and_no_staging_residue(self):
        for writer in BODIES:
            with self.subTest(writer=writer), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                path = root / 'settings.json'
                path.write_text('{"theme":"dark"}\n')
                path.chmod(0o640)
                installed = self.run_writer(writer, root)
                self.assertEqual(installed.returncode, 0, installed.stderr)
                self.assertEqual(path.stat().st_mode & 0o777, 0o640)
                data = json.loads(path.read_text())
                self.assertEqual(data['theme'], 'dark')
                self.assertIn('hooks' if writer == 'merge' else 'extensions', data)
                self.assertFalse(list(root.glob('*.kettle-tmp*')))
                removed = self.run_writer(writer, root, 'remove')
                self.assertEqual(removed.returncode, 0, removed.stderr)
                self.assertEqual(json.loads(path.read_text()), {'theme': 'dark'})
                self.assertEqual(path.stat().st_mode & 0o777, 0o640)
                self.assertFalse(list(root.glob('*.kettle-tmp*')))

    def test_new_configuration_remains_private(self):
        for writer in BODIES:
            with self.subTest(writer=writer), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                result = self.run_writer(writer, root)
                self.assertEqual(result.returncode, 0, result.stderr)
                path = root / 'settings.json'
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                self.assertFalse(path.is_symlink())
                self.assertFalse(list(root.glob('*.kettle-tmp*')))


if __name__ == '__main__':
    unittest.main()
