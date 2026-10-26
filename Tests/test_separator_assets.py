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

    def test_phase2_ci_requires_and_prepares_separator(self):
        root = Path(__file__).resolve().parents[1]
        apple = (root/'Tools/test-apple.sh').read_text(encoding='utf-8')
        workflow = (root/'.github/workflows/apple-validation.yml').read_text(encoding='utf-8')
        self.assertIn('Required two-speaker separator is not prepared', apple)
        self.assertIn('BuildOutputs/Separation/asset-manifest.json', apple)
        self.assertIn('APP_PATH/Separation/Separator.mlmodelc', apple)
        self.assertIn('separator-bundle-assets.log', apple)
        self.assertNotIn('An empty\n  # resource directory keeps model-free builds honest', apple)
        self.assertIn('bash Tools/prepare-separator-macos.sh', workflow)
        self.assertIn("python-version: '3.11'", workflow)
        self.assertIn("inputs.phase == '2' && 120 || 45", workflow)

    def test_pinned_card_accepts_hugging_face_quoted_license(self):
        # Pinned upstream revision 21a5b50 uses: license: "apache-2.0"
        for declared in ('license: "apache-2.0"', "license: 'apache-2.0'", 'license: apache-2.0'):
            with self.subTest(declared=declared):
                exporter.assert_pinned_apache_license('---\nlanguage: "en"\n' + declared + '\n---\n# Model\n')

    def test_pinned_card_rejects_incorrect_missing_or_ambiguous_license(self):
        rejected = (
            '---\nlicense: mit\n---\n',
            '---\nlicense: "apache-2.0\n---\n',
            '---\nlicense: apache-2.0\nlicense: mit\n---\n',
            '---\nmetadata:\n  license: apache-2.0\n---\n',
            '---\nmodel: example\n---\nlicense: apache-2.0\n',
            'license: apache-2.0\n# No YAML metadata\n',
            '---\nlicense: apache-2.0\n# Unterminated front matter',
        )
        for card in rejected:
            with self.subTest(card=card):
                with self.assertRaises(ValueError):
                    exporter.assert_pinned_apache_license(card)

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



    def test_real_audio_fixture_short_mono_is_padded(self):
        import numpy as np
        data = np.ones(16000, dtype=np.float32) * 0.125
        actual, provenance = exporter.prepare_upstream_parity_audio(data, 16000)
        self.assertEqual(actual.shape, (64000,))
        self.assertEqual(provenance['adaptation'], 'zero-padded')
        self.assertTrue(np.all(actual[:16000] == 0.125))
        self.assertTrue(np.all(actual[16000:] == 0))

    def test_real_audio_fixture_stereo_resamples_and_truncates(self):
        import numpy as np
        rate = 48000
        n = 48000 * 5
        t = np.arange(n, dtype=np.float32) / rate
        stereo = np.column_stack((0.1 * np.sin(2*np.pi*220*t),
                                  0.1 * np.sin(2*np.pi*330*t)))
        actual, provenance = exporter.prepare_upstream_parity_audio(stereo, rate)
        self.assertEqual(actual.shape, (64000,))
        self.assertTrue(np.isfinite(actual).all())
        self.assertEqual(provenance['originalChannels'], 2)
        self.assertEqual(provenance['adaptation'], 'truncated')
        self.assertEqual(provenance['availableSamplesAt16k'], 80000)

    def test_real_audio_fixture_rejects_invalid_input(self):
        import numpy as np
        for data, rate in [(np.empty(0, dtype=np.float32), 16000),
                           (np.array([np.nan]), 16000),
                           (np.ones(32000, dtype=np.float32), 0),
                           (np.zeros(32000, dtype=np.float32), 16000),
                           (np.zeros((100, 9), dtype=np.float32), 16000)]:
            with self.subTest(rate=rate, shape=data.shape):
                with self.assertRaises(ValueError):
                    exporter.prepare_upstream_parity_audio(data, rate)

    def test_separator_wrapper_preserves_official_length_adjustment(self):
        source = (TOOLS/'export_separator.py').read_text(encoding='utf-8')
        self.assertIn('requested = mixture.size(1)', source)
        self.assertIn('torch.nn.functional.pad(decoded, (0, 0, 0, requested-actual))', source)
        self.assertIn('return decoded[:, :requested, :]', source)


if __name__ == '__main__':
    unittest.main()
