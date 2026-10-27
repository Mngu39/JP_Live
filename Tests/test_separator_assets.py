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

    def test_alias_coreml_registration_is_narrow_and_preserves_value(self):
        """Execute the exact compatibility callback without requiring CoreML on Linux."""
        registered = {}
        sentinel = object()
        seen = []

        def register(fn):
            registered[fn.__name__] = fn
            return fn

        def inputs(context, node, expected):
            self.assertEqual(expected, 1)
            self.assertIs(context, instance)
            self.assertIs(node, graph_node)
            return [sentinel]

        class Builder:
            @staticmethod
            def identity(*, x, name):
                self.assertIs(x, sentinel)
                self.assertEqual(name, 'masknet/84')
                return ('identity', x, name)

        class Context:
            def add(self, value):
                seen.append(value)

        class Node:
            name = 'masknet/84'

        instance, graph_node = Context(), Node()
        callback = exporter.register_coreml_alias_converter(register, inputs, Builder)
        self.assertIs(registered['alias'], callback)
        callback(instance, graph_node)
        self.assertEqual(seen, [('identity', sentinel, 'masknet/84')])

    def test_torch_alias_in_traced_graph_is_value_preserving(self):
        import torch

        class Example(torch.nn.Module):
            def forward(self, data):
                return torch.ops.aten.alias.default(data) * 3

        data = torch.arange(4, dtype=torch.float32).reshape(1, 4)
        scripted = torch.jit.trace(Example().eval(), data)
        self.assertIn('aten::alias', str(scripted.inlined_graph))
        torch.testing.assert_close(scripted(data), data * 3)

    def test_conversion_debug_reports_all_unsupported_ops(self):
        source = (TOOLS/'export_separator.py').read_text(encoding='utf-8')
        self.assertIn('compute_units=ct.ComputeUnit.CPU_ONLY, debug=True)', source)

    def test_separator_wrapper_preserves_official_length_adjustment(self):
        source = (TOOLS/'export_separator.py').read_text(encoding='utf-8')
        self.assertIn('requested = mixture.size(1)', source)
        self.assertIn('torch.nn.functional.pad(decoded, (0, 0, 0, requested-actual))', source)
        self.assertIn('return decoded[:, :requested, :]', source)

    def test_upstream_torch_reference_runs_before_coreml_convert(self):
        # Guard the exact native-crash sequence from the xcode-27 R5Q run.
        # This is an AST source contract, not a macOS Core ML runtime test.
        import ast
        source = (TOOLS/'export_separator.py').read_text(encoding='utf-8')
        tree = ast.parse(source)
        main = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'main')
        convert = [node for node in ast.walk(main) if isinstance(node, ast.Call)
                   and isinstance(node.func, ast.Attribute) and node.func.attr == 'convert'
                   and isinstance(node.func.value, ast.Name) and node.func.value.id == 'ct']
        self.assertEqual(len(convert), 1)
        reference_calls = [node for node in ast.walk(main) if isinstance(node, ast.Call)
                           and isinstance(node.func, ast.Attribute) and node.func.attr == 'separate_batch']
        self.assertEqual(len(reference_calls), 1)
        self.assertLess(reference_calls[0].lineno, convert[0].lineno)
        self.assertIn('Core ML conversion returned; checking converted-model parity', source)
        self.assertIn('compare_coreml_audio(reference, actual)', source)

    def test_coreml_audio_parity_accepts_high_fidelity_speech(self):
        import numpy as np
        t = np.linspace(0, 1, 64000, dtype=np.float64)
        reference = np.zeros((1, 64000, 2), dtype=np.float32)
        reference[0, :, 0] = 0.6 * np.sin(2 * np.pi * 350 * t)
        reference[0, :, 1] = 0.4 * np.sin(2 * np.pi * 530 * t)
        actual = reference.copy()
        actual[0, :, 0] += 0.0001 * np.sin(2 * np.pi * 49 * t)
        passed, detail = exporter.compare_coreml_audio(reference, actual)
        self.assertTrue(passed, detail)
        self.assertEqual(len(detail['channels']), 2)

    def test_coreml_audio_parity_rejects_wrong_stem_or_spike(self):
        import numpy as np
        t = np.linspace(0, 1, 64000, dtype=np.float64)
        reference = np.zeros((1, 64000, 2), dtype=np.float32)
        reference[0, :, 0] = 0.3 * np.sin(2 * np.pi * 350 * t)
        reference[0, :, 1] = 0.3 * np.sin(2 * np.pi * 530 * t)
        for wrong in (reference[..., ::-1].copy(), reference * 0.8,
                      np.full_like(reference, np.nan)):
            ok, _ = exporter.compare_coreml_audio(reference, wrong)
            self.assertFalse(ok)
        spike = reference.copy(); spike[0, 1000, 0] += 0.1
        ok, _ = exporter.compare_coreml_audio(reference, spike)
        self.assertFalse(ok)

    def test_coreml_audio_parity_silent_stem_stays_silent(self):
        import numpy as np
        reference = np.zeros((1, 64000, 2), dtype=np.float32)
        noisy = reference.copy(); noisy[0, :, 1] = 0.002
        ok, _ = exporter.compare_coreml_audio(reference, noisy)
        self.assertFalse(ok)
        ok, _ = exporter.compare_coreml_audio(reference, reference.copy())
        self.assertTrue(ok)

    def test_sudachi_uses_ci_python_311_not_runner_default(self):
        root = TOOLS.parent
        bash = (root/'Tools/build-sudachi-macos.sh').read_text()
        workflow = (root/'.github/workflows/apple-validation.yml').read_text()
        self.assertIn('python3.11 -m venv', bash)
        self.assertNotIn('python3 -m venv', bash)
        # R5Z uses one validate job for both full and compile-only. Python
        # 3.11 must be configured for Phase 2 before either path runs.
        self.assertIn('  validate:\n', workflow)
        self.assertNotIn('  phase2-source-compile:\n', workflow)
        job = workflow.split('  validate:\n', 1)[1]
        setup = job.split('      - name: Set up Python 3.11 for required separator conversion\n', 1)[1].split('      - name:', 1)[0]
        self.assertIn("if: inputs.phase == '2'", setup)
        self.assertIn('uses: actions/setup-python@v5', setup)
        self.assertIn("python-version: '3.11'", setup)
        self.assertIn("if: inputs.phase == '2' && inputs.phase2_mode == 'compile-only'", job)
        reqs = (root/'Tools/separator-requirements.txt').read_text()
        self.assertIn('torch==2.5.0', reqs)
        self.assertIn('torchaudio==2.5.0', reqs)

    def test_conversion_uses_saved_numpy_inputs_after_torch_reference(self):
        # Reject regression to PyTorch Tensor.numpy() inside post-convert parity.
        source = (TOOLS/'export_separator.py').read_text(encoding='utf-8')
        after_convert = source.split('        model = ct.convert(', 1)[1]
        self.assertNotIn('separator.separate_batch(', after_convert)
        self.assertNotIn('wrapper(example)', after_convert)
        self.assertNotIn('traced(example)', after_convert)
        self.assertNotIn('example.numpy()', after_convert)
        self.assertIn("model.predict({'mixture': mixture_numpy})", after_convert)

    def test_source_compile_preserves_sudachi_failure_log(self):
        # GitHub run #58 failed before Xcode at this step and uploaded no
        # artifact. Require the stage log to survive a non-zero shell exit.
        workflow = (TOOLS.parent/'.github/workflows/apple-validation.yml').read_text(encoding='utf-8')
        step = workflow.split('      - name: Build required Sudachi native framework', 1)[1].split('      - name:', 1)[0]
        self.assertIn('set -euo pipefail', step)
        self.assertIn('mkdir -p BuildOutputs/compile-smoke', step)
        self.assertIn('tee BuildOutputs/compile-smoke/sudachi-build.log', step)
        self.assertIn('BuildOutputs/compile-smoke/*.log', workflow)
        self.assertIn("options: ['full', 'compile-only']", workflow)
        self.assertIn("if: inputs.phase != '2' or inputs.phase2_mode == 'full'", workflow.replace(' || ', ' or '))
        self.assertIn("if: inputs.phase == '2'", workflow)



if __name__ == '__main__':
    unittest.main()
