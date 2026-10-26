"""Download the exact pinned LS-EEND CoreML bundle for JP Live Phase 2."""
from pathlib import Path
import argparse, json, shutil, tempfile

MODEL = "FluidInference/ls-eend-coreml"
REVISION = "62e09c20262f7c7406c7a5e70755e9f957ef09ac"
SOURCE_PATH = "optimized/dih3/100ms/ls_eend_dih3_100ms.mlmodelc"
FLUID_AUDIO_REVISION = "5c19d5e12320e22bbfb7a1877b089d2665a69add"

def prepare(output: Path):
    from huggingface_hub import snapshot_download
    output = output.resolve()
    if output.exists() and any(output.iterdir()):
        raise ValueError(f"refusing to overwrite non-empty diarizer output: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="jp-live-lseend-") as td:
        snap = Path(td) / "snapshot"
        snapshot_download(
            repo_id=MODEL,
            revision=REVISION,
            allow_patterns=[SOURCE_PATH + "/**", "LICENSE"],
            local_dir=snap,
        )
        source = snap / SOURCE_PATH
        license_path = snap / "LICENSE"
        if not source.is_dir():
            raise ValueError(f"pinned LS-EEND model missing: {source}")
        if not license_path.is_file():
            raise ValueError("pinned LS-EEND LICENSE missing")
        staged = Path(td) / "Diarization"
        model_dest = staged / "LSEEND" / "ls_eend_dih3_100ms.mlmodelc"
        model_dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(source, model_dest)
        licenses = staged / "licenses"
        licenses.mkdir()
        shutil.copy2(license_path, licenses / "MIT.txt")
        (staged / "source.json").write_text(json.dumps({
            "schemaVersion": 1,
            "source": MODEL,
            "revision": REVISION,
            "sourcePath": SOURCE_PATH,
            "fluidAudioRevision": FLUID_AUDIO_REVISION,
            "variant": "dihard3",
            "step": "100ms",
            "sampleRate": 8000,
            "runtimePolicy": "bundled-offline-only; no runtime network fallback",
        }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        import diarizer_assets
        manifest = {
            "schemaVersion": 1,
            "source": MODEL,
            "revision": REVISION,
            "license": "MIT",
            "fluidAudioRevision": FLUID_AUDIO_REVISION,
            "variant": "dihard3",
            "step": "100ms",
            "sampleRate": 8000,
            "runtimePolicy": "bundled-offline-only",
            "sha256": diarizer_assets.asset_hashes(staged),
        }
        (staged / "asset-manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        diarizer_assets.verify(staged)
        shutil.move(str(staged), str(output))

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.output)
