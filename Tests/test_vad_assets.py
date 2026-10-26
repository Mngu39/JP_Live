import json
import tempfile
import unittest
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools"))
import vad_assets


class VADAssetTests(unittest.TestCase):
    def test_missing_manifest_fails(self):
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaises(FileNotFoundError):
                vad_assets.verify(Path(td))

    def test_manifest_rejects_unpinned_revision(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / vad_assets.MODEL_DIR).mkdir()
            (root / vad_assets.MODEL_DIR / "coremldata.bin").write_bytes(b"x")
            (root / "licenses").mkdir()
            (root / "licenses/MIT.txt").write_text("MIT License\nPermission is hereby granted\n")
            (root / "licenses/model-card.md").write_text("license: mit\n")
            source = {"source": vad_assets.MODEL, "revision": "wrong", "variant": "silero-vad-unified-256ms-v6.2.1",
                      "sampleRate": 16000, "chunkSize": 4096,
                      "runtimePolicy": "bundled-offline-only; no runtime network fallback"}
            (root / "source.json").write_text(json.dumps(source))
            manifest = {"schemaVersion": 1, "source": vad_assets.MODEL, "revision": "wrong", "license": "MIT",
                        "variant": "silero-vad-unified-256ms-v6.2.1", "sampleRate": 16000,
                        "chunkSize": 4096, "runtimePolicy": "bundled-offline-only",
                        "sha256": vad_assets.asset_hashes(root)}
            (root / "asset-manifest.json").write_text(json.dumps(manifest))
            with self.assertRaises(ValueError):
                vad_assets.verify(root)

    def test_runtime_uses_bundled_model_without_default_downloader(self):
        source = (ROOT / "Shared/ModelAdapters.swift").read_text(encoding="utf-8")
        self.assertIn("silero-vad-unified-256ms-v6.2.1.mlmodelc", source)
        self.assertIn("VadManager(config: .default, vadModel: model)", source)
        self.assertNotIn("manager = try await VadManager()", source)

    def test_phase2_prepares_and_reverifies_vad_in_app_bundle(self):
        workflow = (ROOT / ".github/workflows/apple-validation.yml").read_text(encoding="utf-8")
        apple = (ROOT / "Tools/test-apple.sh").read_text(encoding="utf-8")
        pbx = (ROOT / "Phase2/JPLive.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        self.assertIn("bash Tools/prepare-vad-macos.sh", workflow)
        self.assertIn("BuildOutputs/VAD/asset-manifest.json", apple)
        self.assertIn("APP_PATH/VAD/silero-vad-unified-256ms-v6.2.1.mlmodelc", apple)
        self.assertIn("../BuildOutputs/VAD", pbx)

    def test_dependency_pin_matches_asset_verifier(self):
        deps = json.loads((ROOT / "DEPENDENCIES.json").read_text(encoding="utf-8"))
        item = deps["separatorVADModel"]
        self.assertEqual(item["source"], vad_assets.MODEL)
        self.assertEqual(item["revision"], vad_assets.REVISION)
        self.assertEqual(item["runtimePolicy"], "bundled-offline-only")


if __name__ == "__main__":
    unittest.main()
