#!/usr/bin/env python3
"""Self-contained frontmatter regressions using temporary synthetic records."""

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

VAULT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(VAULT / '.claude/scripts/lib'))
from frontmatter import set_field, split_fence


def record(status='draft'):
    return (
        f'---\nid: demo-session\nstatus: {status}\ncompiled: false\n'
        'tags:\n  - claude-code\n  - in-progress\n---\n'
        '# Demo session\n\nEnded: pending\n\n'
        'Quoted source fields:\nstatus: draft\ncompiled: false\nupdated_at: example\n'
    )


class FrontmatterRegressions(unittest.TestCase):
    def test_metadata_updates_preserve_body(self):
        original = record()
        for key, value in [('compiled', 'true'), ('updated_at', '2000-01-01T00:00:00Z')]:
            with self.subTest(key=key):
                updated, changed = set_field(original, key, value)
                self.assertTrue(changed)
                frontmatter, body, valid = split_fence(updated)
                self.assertTrue(valid)
                self.assertIn(f'{key}: {value}', frontmatter)
                self.assertEqual(body, split_fence(original)[1])

    def test_invalid_fences_are_unchanged(self):
        for text in ['---\nstatus: draft\n\n# Body\n', '# Body\nstatus: draft\n']:
            with self.subTest(text=text):
                self.assertEqual(set_field(text, 'compiled', 'true'), (text, False))

    def test_session_end_preserves_completed_status_and_body(self):
        hook = (VAULT / '.claude/hooks/session-end.sh').read_text(encoding='utf-8')
        script_text = hook.split("python3 <<'PYQUICK'\n", 1)[1].split('\nPYQUICK', 1)[0]
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            script = folder / 'session_end.py'
            script.write_text(script_text, encoding='utf-8')
            for status in ['draft', 'captured', 'promoted']:
                with self.subTest(status=status):
                    source = folder / f'demo-{status}.md'
                    before = record(status)
                    source.write_text(before, encoding='utf-8')
                    environment = dict(os.environ, VAULT_DIR=str(VAULT), SESSION_FILE=str(source),
                                       TIMESTAMP='2000-01-01T00:00:00Z', LOG_FILE=str(folder / 'hook.log'),
                                       PYTHONUTF8='1')
                    result = subprocess.run([sys.executable, str(script)], env=environment,
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    frontmatter, body, valid = split_fence(source.read_text(encoding='utf-8'))
                    self.assertTrue(valid)
                    expected = 'captured' if status == 'draft' else status
                    self.assertIn(f'status: {expected}', frontmatter)
                    self.assertEqual([line for line in body if not line.startswith('Ended:')],
                                     [line for line in split_fence(before)[1] if not line.startswith('Ended:')])

    def test_promotion_failure_quarantines_without_body_damage(self):
        spec = importlib.util.spec_from_file_location('compiler_under_test',
                                                     VAULT / '.claude/scripts/compile-wiki.py')
        compiler = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(compiler)
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            source = folder / 'demo-source.md'
            original = record()
            source.write_text(original, encoding='utf-8')
            compiler.LOG_FILE = folder / 'compile.log'
            reason = "Invalid JSON\nquoted 'value' and 100% output"
            for _ in range(compiler.MAX_COMPILE_ATTEMPTS + 1):
                compiler._mark_failed(source, reason)
            updated = source.read_text(encoding='utf-8')
            metadata = compiler.parse_frontmatter(source)
            self.assertTrue(split_fence(updated)[2])
            self.assertEqual(metadata['compiled'], 'failed')
            self.assertEqual(str(metadata['compile_attempts']), str(compiler.MAX_COMPILE_ATTEMPTS + 1))
            self.assertNotIn('\n', str(metadata['compile_error']))
            self.assertEqual(split_fence(updated)[1], split_fence(original)[1])


if __name__ == '__main__':
    unittest.main()
