"""Portable checks using synthetic files, without a model or MCP installation."""

import ast
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]


def reader_functions(vault):
    tree = ast.parse((ROOT / '.claude/mcp-server/vault_server.py').read_text(encoding='utf-8'))
    selected = []
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name in {
            'vault_indexes', 'vault_read', '_extract_title'
        }:
            node.decorator_list = []
            selected.append(node)
    namespace = {'VAULT_DIR': vault, 'Path': Path, 're': __import__('re')}
    exec(compile(ast.Module(body=selected, type_ignores=[]), '<reader functions>', 'exec'), namespace)
    return namespace


class ReaderBoundaries(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.vault = self.root / 'vault'
        self.indexes = self.vault / 'wiki/indexes'
        self.indexes.mkdir(parents=True)
        (self.indexes / 'concepts.md').write_text('# Concepts\nExample index\n', encoding='utf-8')
        (self.root / 'outside.md').write_text('# OUTSIDE-SENTINEL\n', encoding='utf-8')
        self.functions = reader_functions(self.vault)

    def test_named_index_and_listing(self):
        self.assertIn('Example index', self.functions['vault_indexes']('concepts'))
        self.assertIn('concepts: Concepts', self.functions['vault_indexes']())

    def test_traversal_and_absolute_names_rejected(self):
        for name in ('../../../outside', '../other', '/outside', '..\\outside',
                     str(self.root / 'outside'), 'concepts.md'):
            with self.subTest(name=name):
                self.assertTrue(self.functions['vault_indexes'](name).startswith('ERROR:'))

    def test_missing_index_is_error(self):
        self.assertTrue(self.functions['vault_indexes']('missing').startswith('ERROR:'))

    def test_directory_is_not_index_file(self):
        (self.indexes / 'directory.md').mkdir()
        self.assertTrue(self.functions['vault_indexes']('directory').startswith('ERROR:'))
        self.assertNotIn('directory:', self.functions['vault_indexes']())

    def test_general_reader_rejects_outside_path(self):
        self.assertTrue(self.functions['vault_read']('../outside').startswith('ERROR:'))
        self.assertIn('Example index', self.functions['vault_read']('wiki/indexes/concepts'))

    def make_symlink(self, path, target, is_directory=False):
        try:
            path.symlink_to(target, target_is_directory=is_directory)
        except OSError as exc:
            self.skipTest(f'Platform does not permit symbolic links: {exc}')

    def test_index_symlink_escape_rejected_and_not_listed(self):
        self.make_symlink(self.indexes / 'leak.md', self.root / 'outside.md')
        self.assertTrue(self.functions['vault_indexes']('leak').startswith('ERROR:'))
        self.assertNotIn('OUTSIDE-SENTINEL', self.functions['vault_indexes']())
        self.assertNotIn('leak:', self.functions['vault_indexes']())

    def test_index_symlink_to_other_vault_directory_rejected(self):
        note = self.vault / 'private.md'
        note.write_text('# PRIVATE-SENTINEL\n', encoding='utf-8')
        self.make_symlink(self.indexes / 'private.md', note)
        self.assertTrue(self.functions['vault_indexes']('private').startswith('ERROR:'))

    def test_index_directory_symlink_outside_vault_rejected(self):
        alternate = self.root / 'alternate-vault'
        (alternate / 'wiki').mkdir(parents=True)
        self.make_symlink(alternate / 'wiki/indexes', self.indexes, is_directory=True)
        functions = reader_functions(alternate)
        self.assertTrue(functions['vault_indexes']('concepts').startswith('ERROR:'))
        self.assertTrue(functions['vault_indexes']().startswith('ERROR:'))


class MatcherBehavior(unittest.TestCase):
    def test_exact_match_and_documented_misses(self):
        hook = (ROOT / '.claude/hooks/user-prompt-workbench-match.sh').read_text(encoding='utf-8')
        code = hook.split("<<'PY' 2>/dev/null || true\n", 1)[1].split('\nPY\n', 1)[0]
        cases = [('postgres', 'Help with postgres', True),
                 ('postgres', 'Help with PostgreSQL', False),
                 ('"postgres"', 'Help with postgres', False),
                 ('obs', 'Help with OBS', False)]
        with tempfile.TemporaryDirectory() as folder:
            workbench = Path(folder) / 'wiki/workbench'
            workbench.mkdir(parents=True)
            for tag, prompt, expected in cases:
                with self.subTest(tag=tag, prompt=prompt):
                    (workbench / 'demo.md').write_text(
                        f'---\ntech_surface: [{tag}]\n---\n# Demo\n', encoding='utf-8')
                    output = io.StringIO()
                    with patch.dict(os.environ, {'HOOK_INPUT': json.dumps({'prompt': prompt})}), \
                         patch.object(sys, 'argv', ['matcher', folder]), \
                         contextlib.redirect_stdout(output):
                        try:
                            exec(compile(code, '<embedded matcher>', 'exec'), {})
                        except SystemExit as exc:
                            self.assertEqual(exc.code, 0)
                    self.assertEqual('Demo' in output.getvalue(), expected)


class FrontmatterPreservation(unittest.TestCase):
    def test_metadata_update_does_not_edit_quoted_body_fields(self):
        path = ROOT / '.claude/scripts/lib/frontmatter.py'
        spec = importlib.util.spec_from_file_location('frontmatter_under_test', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        original = '---\nstatus: draft\n---\n# Evidence\nstatus: draft\ncompiled: false\n'
        updated, changed = module.set_field(original, 'status', 'promoted')
        self.assertTrue(changed)
        self.assertIn('status: promoted', updated.split('---')[1])
        self.assertEqual(updated.split('---', 2)[2], original.split('---', 2)[2])


if __name__ == '__main__':
    unittest.main()
