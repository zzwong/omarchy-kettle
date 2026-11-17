#!/usr/bin/env python3
"""Execute exact in-memory merge logic only, never an installer or writer."""
import contextlib
import copy
import io
import os
from pathlib import Path
import shlex
import sys
import unittest

source = Path(sys.argv.pop(1)).read_text()
start = source.index('if style == "bare":')
marker = '\nif changed:\n'
assert source.count(marker) == 1, 'ambiguous final writer boundary'
end = source.index(marker, start)
logic = source[start:end]
assert not any(t in logic for t in ('open(', 'os.makedirs', 'os.chmod', 'os.replace', 'subprocess', 'socket'))
HOOK = '/synthetic/current clone/bin/kettle-agent-hook'
OLD = '/synthetic/old/bin/kettle-agent-hook'

def hook(command, **extra):
    return {'type': 'command', 'command': command, **extra}

def config(style, groups):
    items = {'Stop': groups, 'Unrelated': [{'hooks': [hook('/synthetic/foreign')]}]}
    return items if style == 'bare' else {'theme': 'unchanged', 'hooks': items}

def groups(doc, style):
    return (doc if style == 'bare' else doc.get('hooks', {})).get('Stop', [])

def merge(doc, mode, style='wrapped'):
    ns = dict(doc=copy.deepcopy(doc), mode=mode, style=style, hook=HOOK,
              unit='s', use_async='yes', events=['Stop'], os=os, shlex=shlex, sys=sys)
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        try:
            exec(logic, ns)
        except SystemExit as stop:
            if mode != 'check' or stop.code != 0:
                raise
    return ns['doc'], ns['changed'], output.getvalue()

class InstallerOwnership(unittest.TestCase):
    def test_foreign_commands_are_preserved(self):
        commands = ["printf '%s' 'kettle-agent-hook'", '/synthetic/not-kettle-agent-hook',
                    '/bin/echo /synthetic/kettle-agent-hook', '/synthetic/kettle-agent-hook.backup',
                    'kettle-agent-hook', '/synthetic/$(unknown)/kettle-agent-hook',
                    '/synthetic/kettle-agent-hook; echo extra', '"unterminated/kettle-agent-hook']
        for style in ('wrapped', 'bare'):
            for command in commands:
                with self.subTest(style=style, command=command):
                    original = config(style, [{'hooks': [hook(command, foreign=True)]}])
                    for mode in ('remove', 'check'):
                        result, changed, _ = merge(original, mode, style)
                        self.assertEqual(result, original)
                        self.assertFalse(changed)
                    result, changed, _ = merge(original, 'install', style)
                    self.assertTrue(changed)
                    self.assertEqual(groups(result, style)[0], groups(original, style)[0])
                    self.assertEqual(groups(result, style)[1]['hooks'][0]['command'], HOOK)

    def test_moved_and_quoted_clone_paths_remain_owned(self):
        for style in ('wrapped', 'bare'):
            for command in (OLD, '"/synthetic/old clone/bin/kettle-agent-hook"',
                            '/synthetic/old\\ clone/bin/kettle-agent-hook'):
                with self.subTest(style=style, command=command):
                    original = config(style, [{'hooks': [hook(command, timeout=5)]}])
                    installed, changed, _ = merge(original, 'install', style)
                    self.assertTrue(changed)
                    self.assertEqual(groups(installed, style), [{'hooks': [hook(HOOK, timeout=5)]}])
                    removed, changed, _ = merge(original, 'remove', style)
                    self.assertTrue(changed)
                    self.assertEqual(groups(removed, style), [])

    def test_current_path_with_spaces_remains_owned(self):
        original = config('wrapped', [{'hooks': [hook(HOOK)]}])
        installed, changed, _ = merge(original, 'install')
        self.assertEqual(installed, original)
        self.assertFalse(changed)
        removed, changed, _ = merge(original, 'remove')
        self.assertEqual(groups(removed, 'wrapped'), [])
        self.assertTrue(changed)

    def test_ambiguous_unquoted_legacy_path_is_preserved(self):
        original = config('wrapped', [{'hooks': [hook('/synthetic/old clone/bin/kettle-agent-hook')]}])
        result, changed, _ = merge(original, 'remove')
        self.assertEqual(result, original)
        self.assertFalse(changed)

    def test_mixed_group_preserves_foreign_and_metadata(self):
        foreign = hook('/synthetic/foreign', timeout=23, extra='preserve')
        group = {'matcher': '*', 'metadata': {'nested': True}, 'hooks': [hook(OLD), foreign, hook(HOOK)]}
        for style in ('wrapped', 'bare'):
            with self.subTest(style=style):
                original = config(style, [group])
                result, changed, _ = merge(original, 'remove', style)
                self.assertTrue(changed)
                self.assertEqual(groups(result, style), [{**group, 'hooks': [foreign]}])
                self.assertEqual((result if style == 'bare' else result['hooks'])['Unrelated'],
                                 (original if style == 'bare' else original['hooks'])['Unrelated'])

    def test_repeated_install_remove_is_idempotent(self):
        for style in ('wrapped', 'bare'):
            with self.subTest(style=style):
                original = config(style, [{'hooks': [hook('/synthetic/foreign')]}])
                installed, changed, _ = merge(original, 'install', style)
                self.assertTrue(changed)
                again, changed, _ = merge(installed, 'install', style)
                self.assertEqual(again, installed)
                self.assertFalse(changed)
                removed, changed, _ = merge(again, 'remove', style)
                self.assertEqual(removed, original)
                self.assertTrue(changed)
                again, changed, _ = merge(removed, 'remove', style)
                self.assertEqual(again, original)
                self.assertFalse(changed)

    def test_non_string_commands_and_check_preserve_input(self):
        for command in (None, 12, {'note': 'kettle-agent-hook'}, ['kettle-agent-hook']):
            with self.subTest(command=command):
                original = config('wrapped', [{'hooks': [hook(command)]}])
                result, changed, _ = merge(original, 'remove')
                self.assertEqual(result, original)
                self.assertFalse(changed)
        original = config('wrapped', [{'hooks': [hook(OLD)]}])
        result, changed, output = merge(original, 'check')
        self.assertEqual(result, original)
        self.assertFalse(changed)
        self.assertIn('ok', output)

    def test_all_owned_groups_are_removed_without_empty_wrappers(self):
        wrapped = {'theme': 'unchanged', 'hooks': {'Stop': [{'hooks': [hook(OLD)]}]}}
        result, changed, _ = merge(wrapped, 'remove')
        self.assertEqual(result, {'theme': 'unchanged'})
        self.assertTrue(changed)
        result, changed, _ = merge({'Stop': [{'hooks': [hook(OLD)]}]}, 'remove', 'bare')
        self.assertEqual(result, {})
        self.assertTrue(changed)

    def test_non_command_hook_types_are_not_owned(self):
        for style in ('wrapped', 'bare'):
            for command in (OLD, HOOK):
                with self.subTest(style=style, command=command):
                    item = {'type': 'prompt', 'command': command, 'prompt': 'synthetic'}
                    original = config(style, [{'hooks': [item]}])
                    result, changed, _ = merge(original, 'remove', style)
                    self.assertEqual(result, original)
                    self.assertFalse(changed)
                    result, changed, _ = merge(original, 'install', style)
                    self.assertTrue(changed)
                    self.assertEqual(groups(result, style)[0], {'hooks': [item]})

    def test_repointing_preserves_foreign_sibling_values(self):
        foreign = hook('/synthetic/foreign', timeout=31)
        group = {'matcher': 'unchanged', 'hooks': [hook(OLD), foreign]}
        original = config('wrapped', [group])
        result, changed, _ = merge(original, 'install')
        self.assertTrue(changed)
        self.assertEqual(groups(result, 'wrapped'), [{**group, 'hooks': [hook(HOOK), foreign]}])

if __name__ == '__main__':
    unittest.main()
