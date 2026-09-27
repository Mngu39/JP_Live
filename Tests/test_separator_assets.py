"""Local fixtures test artifact validation, NOT actual ML conversion or quality."""
from pathlib import Path
import importlib.util
import json
import sys
import tempfile
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[1]/'Tools'
sys.path.insert(0, str(TOOLS))
import separator_assets as assets
import export_separator as exporter


class SeparatorAssetsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)/'Separation'

    def fixture(self):
        for name in ('Separator.mlmodelc/model.bin', 'licenses/Apache-2.0.txt',
                     'licenses/model-card.md', 'conversion-report.json'):
            path = self.root/name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'fixture only - not real model assets')
        self.report = {'source': assets.MODEL, 'revision': assets.REVISION, 'license': 'Apache-2.0',
                       'shape': [1, 64000, 2], 'parityPassed': True,
                       'sourceSHA256': {name: '0'*64 for name in assets.SOURCE_FILES},
                       'checks': [{'case': case, 'passed': True, 'maxAbsoluteError': 0, 'hostSeconds': 1}
                                  for case in sorted(assets.PARITY_CASES)]}
        (self.root/'conversion-report.json').write_text(json.dumps(self.report), encoding='utf-8')
        self.manifest = {'schemaVersion': 1, 'source': assets.MODEL, 'revision': assets.REVISION,
                         'license': 'Apache-2.0', 'sampleRate': 16000,
                         'input': [1, 64000], 'output': [1, 64000, 2],
                         'sha256': assets.asset_hashes(self.root),
                         'validation': 'conversion-parity-passed; Japanese/device NOT VERIFIED'}
        self.save()

    def save(self):
        (self.root/'asset-manifest.json').write_text(json.dumps(self.manifest), encoding='utf-8')

    def save_report_and_rehash(self):
        (self.root/'conversion-report.json').write_text(json.dumps(self.report), encoding='utf-8')
        self.manifest['sha256'] = assets.asset_hashes(self.root)
        self.save()

    def test_report_not_just_its_checksum_is_validated(self):
        self.fixture()
        self.report = {}; self.save_report_and_rehash()
        with self.assertRaisesRegex(ValueError, 'report'): assets.verify(self.root)

    def test_report_requires_all_parity_cases(self):
        self.fixture()
        self.report['checks'].pop(); self.save_report_and_rehash()
        with self.assertRaisesRegex(ValueError, 'parity cases'): assets.verify(self.root)

    def test_report_rejects_failed_nonfinite_and_mismatched_provenance(self):
        self.fixture()
        original = json.dumps(self.report)
        for field, value in [('passed', False), ('maxAbsoluteError', float('nan')), ('hostSeconds', -1)]:
            self.report = json.loads(original); self.report['checks'][0][field] = value
            self.save_report_and_rehash()
            with self.assertRaises(ValueError): assets.verify(self.root)
        self.report = json.loads(original); self.report['revision'] = '0'*40
        self.save_report_and_rehash()
        with self.assertRaises(ValueError): assets.verify(self.root)

    def test_absent_and_empty_are_explicitly_unprepared(self):
        self.assertEqual(assets.verify(self.root)['status'], 'MODEL_NOT_PREPARED')
        self.root.mkdir()
        self.assertFalse(assets.verify(self.root)['liveSeparation'])

    def test_valid_fixture_never_claims_japanese_or_device_validation(self):
        self.fixture()
        result = assets.verify(self.root)
        self.assertEqual(result['files'], 4)
        self.assertEqual(result['JapaneseQuality'], 'NOT VERIFIED')
        self.assertEqual(result['iPadPerformance'], 'NOT VERIFIED')

    def test_changed_model_is_rejected(self):
        self.fixture()
        (self.root/'Separator.mlmodelc/model.bin').write_bytes(b'changed')
        with self.assertRaises(ValueError): assets.verify(self.root)

    def test_extra_file_is_rejected(self):
        self.fixture()
        (self.root/'unrecorded.bin').write_bytes(b'extra')
        with self.assertRaises(ValueError): assets.verify(self.root)

    def test_incomplete_model_folder_is_not_treated_as_missing(self):
        (self.root/'Separator.mlmodelc').mkdir(parents=True)
        with self.assertRaises(FileNotFoundError): assets.verify(self.root)

    def test_revision_and_shape_mismatch_are_rejected(self):
        self.fixture()
        for key, value in [('revision', '0'*40), ('sampleRate', 8000), ('output', [1, 64000])]:
            old = self.manifest[key]; self.manifest[key] = value; self.save()
            with self.assertRaises(ValueError): assets.verify(self.root)
            self.manifest[key] = old

    def test_unsafe_manifest_paths_are_rejected(self):
        self.fixture()
        for name in ('../outside', '/absolute', 'C:/absolute', 'bad\\name', 'bad\rname', '#Uac00.txt'):
            self.manifest['sha256'][name] = '0'*64; self.save()
            with self.assertRaises(ValueError): assets.verify(self.root)
            del self.manifest['sha256'][name]

    def test_license_evidence_cannot_be_omitted_with_recomputed_hashes(self):
        self.fixture()
        (self.root/'licenses/Apache-2.0.txt').unlink()
        self.manifest['sha256'] = assets.asset_hashes(self.root); self.save()
        with self.assertRaises(ValueError): assets.verify(self.root)

    def test_preflight_fails_on_windows_before_importing_ml_packages(self):
        with patch.object(exporter.platform, 'system', return_value='Windows'):
            with self.assertRaisesRegex(ValueError, 'require macOS'):
                exporter.preflight(self.root/'Separator.mlpackage', None)

    def test_preflight_does_not_overwrite_existing_model(self):
        self.root.mkdir()
        output = self.root/'Separator.mlpackage'; output.mkdir()
        with patch.object(exporter.platform, 'system', return_value='Darwin'), \
             patch.object(exporter.sys, 'version_info', (3, 11)), \
             patch.object(exporter.shutil, 'which', return_value='/usr/bin/xcrun'):
            with self.assertRaisesRegex(ValueError, 'fresh'):
                exporter.preflight(output, None)
        self.assertTrue(output.is_dir())


if __name__ == '__main__':
    unittest.main()
