import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('security_runner', Path(__file__).with_name('run.py'))
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class QueueValidationTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.path = self.root / '.github/workflows/website-preview.yml'
        self.path.parent.mkdir(parents=True)
        self.source = ('    concurrency:\n'
                       '      group: website-preview-publish\n'
                       '      cancel-in-progress: false\n'
                       '      queue: max\n')
        self.error = {
            'message': 'unexpected key "queue" for "concurrency" section. expected one of "cancel-in-progress", "group"',
            'filepath': '.github/workflows/website-preview.yml',
            'line': 4, 'column': 7, 'kind': 'syntax-check',
        }

    def lint(self, source=None, errors=None, returncode=1):
        self.path.write_text(self.source if source is None else source)
        result = subprocess.CompletedProcess([], returncode, json.dumps(errors if errors is not None else [self.error]), '')
        with patch.object(runner.subprocess, 'run', return_value=result), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return runner.lint_actions('/verified/actionlint', self.root)

    def test_accepts_only_the_supported_preview_queue_block(self):
        self.assertEqual(self.lint(), 0)

    def test_invalid_queue_and_cancel_combinations_fail(self):
        for source in (self.source.replace('max', 'invalid'), self.source.replace('false', 'true'),
                       self.source.replace('website-preview-publish', 'other-group'),
                       self.source.replace('    concurrency:', '    steps:')):
            with self.subTest(source=source):
                self.assertNotEqual(self.lint(source=source), 0)

    def test_other_diagnostics_still_fail(self):
        for changes in ({'message': 'unknown action input'}, {'kind': 'expression'},
                        {'filepath': '.github/workflows/other.yml'}, {'line': 1}, {'column': 3}):
            with self.subTest(changes=changes):
                self.assertNotEqual(self.lint(errors=[{**self.error, **changes}]), 0)
        self.assertNotEqual(self.lint(errors=[self.error, {**self.error, 'message': 'invalid expression'}]), 0)

    def test_tool_failures_are_not_converted_to_success(self):
        self.assertNotEqual(self.lint(errors=[], returncode=1), 0)
        self.assertNotEqual(self.lint(returncode=2), 0)

    def test_successful_newer_linter_needs_no_exception(self):
        self.assertEqual(self.lint(errors=[], returncode=0), 0)
