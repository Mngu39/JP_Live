"""Portable regression tests for the real packaging/preflight manifest helper."""
from pathlib import Path
import hashlib
import importlib.util
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('source_checksums', Path(__file__).resolve().parents[1] / 'Tools/source_checksums.py')
checksums = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checksums)


class SourceChecksumTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.path = self.root / '공백 있는 파일.swift'
        self.content = b'let value = 1\r\nlet next = 2\n'
        self.path.write_bytes(self.content)
        self.line = f'{hashlib.sha256(self.content).hexdigest()}  {self.path.name}\n'.encode('utf-8')

    def test_windows_generation_writes_only_lf_and_hashes_original_bytes(self):
        self.assertEqual(checksums.generate(self.root), 1)
        manifest = (self.root / 'SHA256SUMS.txt').read_bytes()
        self.assertEqual(manifest, self.line)
        self.assertNotIn(b'\r', manifest)
        self.assertEqual(self.path.read_bytes(), self.content)

    def test_lf_crlf_and_mixed_manifest_record_endings(self):
        extra = self.root / 'next.txt'
        extra.write_bytes(b'next')
        second = f'{hashlib.sha256(b"next").hexdigest()}  next.txt\n'.encode()
        for data in [self.line + second, (self.line + second).replace(b'\n', b'\r\n'),
                     self.line.replace(b'\n', b'\r\n') + second]:
            self.assertEqual(checksums.verify(self.root, data), 2)
            self.assertEqual(checksums.normalize(data), self.line + second)
        self.assertEqual(self.path.read_bytes(), self.content)

    def test_changed_source_fails_with_lf_and_crlf_manifests(self):
        self.path.write_bytes(b'changed source')
        for manifest in [self.line, self.line.replace(b'\n', b'\r\n')]:
            with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
                checksums.verify(self.root, manifest)

    def test_changed_source_line_endings_are_not_hidden(self):
        self.path.write_bytes(self.content.replace(b'\r\n', b'\n'))
        with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
            checksums.verify(self.root, self.line)

    def test_missing_source_still_fails(self):
        self.path.unlink()
        with self.assertRaises(FileNotFoundError):
            checksums.verify(self.root, self.line.replace(b'\n', b'\r\n'))

    def test_carriage_return_inside_hash_or_filename_is_not_removed(self):
        for data in [self.line[:10] + b'\r' + self.line[10:], self.line[:-2] + b'\r' + self.line[-2:]]:
            with self.assertRaises(ValueError):
                checksums.normalize(data)

    def test_bad_empty_and_duplicate_records_fail(self):
        for data in [b'', b'\n', b'broken\n', self.line + self.line]:
            with self.assertRaises(ValueError):
                checksums.normalize(data)

    def test_build_outputs_and_git_metadata_are_not_source_records(self):
        for name in ['.git/config', 'BuildOutputs/failed/checksums.log', 'Tools/__pycache__/cache.pyc']:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'not source')
        self.assertEqual(checksums.generate(self.root), 1)
        self.assertEqual((self.root / 'SHA256SUMS.txt').read_bytes(), self.line)


if __name__ == '__main__':
    unittest.main()
