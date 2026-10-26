from pathlib import Path
import json
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1] / "Tools"
sys.path.insert(0, str(TOOLS))
import diarizer_assets as assets

class DiarizerAssetsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "Diarization"

    def fixture(self):
        model = self.root / "LSEEND/ls_eend_dih3_100ms.mlmodelc"
        model.mkdir(parents=True, exist_ok=True)
        (model / "model.mil").write_bytes(b"fixture model")
        (self.root / "licenses").mkdir(exist_ok=True)
        (self.root / "licenses/MIT.txt").write_text("MIT fixture", encoding="utf-8")
        source = {
            "schemaVersion": 1,
            "source": assets.MODEL,
            "revision": assets.REVISION,
            "sourcePath": "optimized/dih3/100ms/ls_eend_dih3_100ms.mlmodelc",
            "fluidAudioRevision": assets.FLUID_AUDIO_REVISION,
            "variant": "dihard3",
            "step": "100ms",
            "sampleRate": 8000,
            "runtimePolicy": "bundled-offline-only; no runtime network fallback",
        }
        (self.root / "source.json").write_text(json.dumps(source), encoding="utf-8")
        manifest = {
            "schemaVersion": 1,
            "source": assets.MODEL,
            "revision": assets.REVISION,
            "license": "MIT",
            "fluidAudioRevision": assets.FLUID_AUDIO_REVISION,
            "variant": "dihard3",
            "step": "100ms",
            "sampleRate": 8000,
            "runtimePolicy": "bundled-offline-only",
            "sha256": assets.asset_hashes(self.root),
        }
        (self.root / "asset-manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        return manifest

    def test_valid_fixture(self):
        self.fixture()
        result = assets.verify(self.root)
        self.assertEqual(result["status"], "BUNDLED_LSEEND_VERIFIED")

    def test_changed_model_and_extra_file_are_rejected(self):
        self.fixture()
        (self.root / "LSEEND/ls_eend_dih3_100ms.mlmodelc/model.mil").write_bytes(b"changed")
        with self.assertRaises(ValueError):
            assets.verify(self.root)
        self.fixture()
        (self.root / "extra.bin").write_bytes(b"x")
        with self.assertRaises(ValueError):
            assets.verify(self.root)

    def test_revision_license_and_runtime_policy_are_pinned(self):
        manifest = self.fixture()
        for key, value in [
            ("revision", "0"*40),
            ("license", "Apache-2.0"),
            ("runtimePolicy", "runtime-download"),
        ]:
            old = manifest[key]
            manifest[key] = value
            (self.root / "asset-manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaises(ValueError):
                assets.verify(self.root)
            manifest[key] = old

    def test_runtime_uses_bundled_model_without_network_fallback(self):
        source = (Path(__file__).resolve().parents[1] / "Shared/ModelAdapters.swift").read_text(encoding="utf-8")
        self.assertIn("bundledRelativeModelPath", source)
        self.assertIn("LSEENDModel(modelURL: modelURL", source)
        self.assertNotIn("loadFromHuggingFace", source)
        self.assertNotIn("initialize(variant: .dihard3", source)

    def test_phase2_prepares_and_verifies_diarizer_in_actual_app_bundle(self):
        repo = Path(__file__).resolve().parents[1]
        workflow = (repo / ".github/workflows/apple-validation.yml").read_text(encoding="utf-8")
        apple = (repo / "Tools/test-apple.sh").read_text(encoding="utf-8")
        pbx = (repo / "Phase2/JPLive.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        self.assertIn("bash Tools/prepare-diarizer-macos.sh", workflow)
        self.assertIn("BuildOutputs/Diarization/asset-manifest.json", apple)
        self.assertIn("APP_PATH/Diarization/LSEEND/ls_eend_dih3_100ms.mlmodelc", apple)
        self.assertIn("diarizer-bundle-assets.log", apple)
        self.assertIn("../BuildOutputs/Diarization", pbx)
        self.assertIn("B23000000000000000000002", pbx)

    def test_dependency_pin_matches_asset_verifier(self):
        deps = json.loads((Path(__file__).resolve().parents[1] / "DEPENDENCIES.json").read_text(encoding="utf-8"))
        item = deps["liveDiarizerModel"]
        self.assertEqual(item["source"], assets.MODEL)
        self.assertEqual(item["revision"], assets.REVISION)
        self.assertEqual(item["fluidAudioRevision"], assets.FLUID_AUDIO_REVISION)
        self.assertEqual(item["runtimePolicy"], "bundled-offline-only")

if __name__ == "__main__":
    unittest.main()
