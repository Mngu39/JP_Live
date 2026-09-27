"""Resource packaging regressions; fake fixture files, not a dictionary-quality test."""
from pathlib import Path
import importlib.util
import json
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('prepare_sudachi', Path(__file__).parents[1]/'Tools/prepare-sudachi-resources.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class Distribution:
    def __init__(self, root, version, files, license_name='Apache-2.0'):
        self.root, self.version, self.files = root, version, [Path(p) for p in files]
        self.metadata = {'License': license_name}
    def locate_file(self, file): return self.root/file

class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        fixtures = {
            'sudachipy/resources/sudachi.json': '{"systemDict":"old.dic","userDict":["old-user.dic"]}',
            'sudachipy/resources/char.def': 'fixture',
            'sudachidict_full/resources/system.dic': 'dictionary fixture, not executable',
            'sudachipy.dist-info/licenses/LICENSE': 'license fixture',
            'sudachidict_full.dist-info/licenses/LICENSE': 'dictionary license fixture',
        }
        for name, value in fixtures.items():
            p = self.root/name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(value, encoding='utf-8')
        self.packages = {
            'SudachiPy': Distribution(self.root, module.VERSIONS['SudachiPy'], ['sudachipy.dist-info/licenses/LICENSE']),
            'SudachiDict-full': Distribution(self.root, module.VERSIONS['SudachiDict-full'], ['sudachidict_full.dist-info/licenses/LICENSE']),
        }
        self.output = self.root/'새 사전'
        patcher = patch.object(module.importlib.metadata, 'distribution', side_effect=self.packages.__getitem__)
        patcher.start(); self.addCleanup(patcher.stop)

    def test_staged_config_licenses_and_hashes(self):
        count = module.prepare(self.output)
        config = json.loads((self.output/'sudachi.json').read_text(encoding='utf-8'))
        self.assertEqual(config['systemDict'], 'system.dic')
        self.assertEqual(config['userDict'], [])
        manifest = json.loads((self.output/'asset-manifest.json').read_text(encoding='utf-8'))
        self.assertEqual(len(manifest['sha256']), count)
        for name, expected in manifest['sha256'].items():
            self.assertEqual(module.hashlib.sha256((self.output/name).read_bytes()).hexdigest(), expected)
        self.assertEqual(len(list((self.output/'licenses').rglob('LICENSE'))), 2)

    def test_missing_packaged_license_uses_verified_metadata_evidence(self):
        self.packages['SudachiPy'].files = []
        module.prepare(self.output)
        marker = self.output/'licenses/SudachiPy/PACKAGE-LICENSE-METADATA.txt'
        self.assertTrue(marker.is_file())
        text = marker.read_text(encoding='utf-8')
        self.assertIn('Declared-License: Apache-2.0', text)
        self.assertIn('Packaged-License-File: absent', text)

    def test_missing_packaged_license_with_unexpected_metadata_is_rejected(self):
        self.packages['SudachiPy'].files = []
        self.packages['SudachiPy'].metadata['License'] = 'unexpected'
        with self.assertRaisesRegex(ValueError, 'expected'):
            module.prepare(self.output)

    def test_version_pins_match_build_script_and_dependency_inventory(self):
        root = Path(__file__).parents[1]
        script = (root/'Tools/build-sudachi-macos.sh').read_text(encoding='utf-8')
        inventory = json.loads((root/'DEPENDENCIES.json').read_text(encoding='utf-8'))['Sudachi']['resourcePackages']
        for name, version in module.VERSIONS.items():
            self.assertIn(f"'{name}=={version}'", script)
            self.assertEqual(inventory[name], version)

    def test_xcframework_headers_are_namespaced(self):
        root = Path(__file__).parents[1]
        script = (root/'Tools/build-sudachi-macos.sh').read_text(encoding='utf-8')
        self.assertIn('XC_HEADERS="$STAGE/XCHeaders"', script)
        self.assertIn('mkdir -p "$XC_HEADERS/SudachiBridge"', script)
        self.assertIn(
            'cp include/SudachiBridge.h include/module.modulemap "$XC_HEADERS/SudachiBridge/"',
            script,
        )
        self.assertEqual(script.count('-headers "$XC_HEADERS"'), 2)
        self.assertNotIn('-headers include', script)

    def test_rust_and_resource_version_family_stays_compatible(self):
        root = Path(__file__).parents[1]
        cargo = (root/'Native/SudachiBridge/Cargo.toml').read_text(encoding='utf-8')
        revision = '90fd6068c80c2fc3b63e0dbab0e341475bad4d8f'
        self.assertIn(f'rev = "{revision}"', cargo)
        # This pinned Rust revision is Sudachi 0.6.11. Keep its resource/parser
        # family on 0.6.x; SudachiPy 0.7 resources contain categories/formats
        # that this native parser does not support.
        self.assertEqual(module.VERSIONS, {
            'SudachiPy': '0.6.11',
            'SudachiDict-full': '20260723',
        })

    def test_version_mismatch_rejected(self):
        self.packages['SudachiPy'].version = 'unexpected'
        with self.assertRaisesRegex(ValueError, 'expected'): module.prepare(self.output)
        self.assertFalse(self.output.exists())

    def test_existing_output_not_overwritten(self):
        self.output.mkdir(); (self.output/'keep').write_text('keep')
        with self.assertRaisesRegex(ValueError, 'fresh staging'): module.prepare(self.output)
        self.assertEqual((self.output/'keep').read_text(), 'keep')

    def test_missing_dictionary_rejected(self):
        (self.root/'sudachidict_full/resources/system.dic').unlink()
        with self.assertRaisesRegex(ValueError, 'expected resources'): module.prepare(self.output)

if __name__ == '__main__': unittest.main()
