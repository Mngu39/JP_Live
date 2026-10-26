"""Stage the exact pinned Silero VAD Core ML bundle for offline Phase 2 use."""
from pathlib import Path
import argparse, json, shutil, tempfile, urllib.request
from huggingface_hub import snapshot_download
from vad_assets import MODEL, REVISION, MODEL_DIR, asset_hashes, verify

UPSTREAM_LICENSE = "https://raw.githubusercontent.com/snakers4/silero-vad/v6.2.1/LICENSE"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    out = args.output
    if out.exists():
        raise ValueError(f"Refusing to overwrite existing VAD output: {out}")
    out.parent.mkdir(parents=True, exist_ok=True)
    snapshot = Path(snapshot_download(repo_id=MODEL, revision=REVISION,
        allow_patterns=[f"{MODEL_DIR}/**", "README.md", "config.json"]))
    model = snapshot / MODEL_DIR
    if not model.is_dir():
        raise ValueError("Pinned VAD snapshot lacks the required v6.2.1 compiled model")
    card = (snapshot / "README.md").read_text(encoding="utf-8")
    if "license: mit" not in card.lower():
        raise ValueError("Pinned VAD model card no longer declares MIT")
    with urllib.request.urlopen(UPSTREAM_LICENSE, timeout=30) as response:
        license_text = response.read().decode("utf-8")
    if "MIT License" not in license_text or "Permission is hereby granted" not in license_text:
        raise ValueError("Could not retrieve the reviewed Silero MIT license")

    ready = Path(tempfile.mkdtemp(prefix="vad-ready-", dir=out.parent))
    try:
        shutil.copytree(model, ready / MODEL_DIR)
        (ready / "licenses").mkdir()
        (ready / "licenses/MIT.txt").write_text(license_text, encoding="utf-8", newline="\n")
        (ready / "licenses/model-card.md").write_text(card, encoding="utf-8", newline="\n")
        source = {
            "source": MODEL, "revision": REVISION,
            "variant": "silero-vad-unified-256ms-v6.2.1",
            "sampleRate": 16000, "chunkSize": 4096,
            "runtimePolicy": "bundled-offline-only; no runtime network fallback",
            "upstream": "snakers4/silero-vad", "upstreamVersion": "v6.2.1",
        }
        (ready / "source.json").write_text(json.dumps(source, indent=2)+"\n", encoding="utf-8", newline="\n")
        manifest = {
            "schemaVersion": 1, "source": MODEL, "revision": REVISION, "license": "MIT",
            "variant": source["variant"], "sampleRate": 16000, "chunkSize": 4096,
            "runtimePolicy": "bundled-offline-only", "sha256": asset_hashes(ready),
        }
        (ready / "asset-manifest.json").write_text(json.dumps(manifest, indent=2)+"\n", encoding="utf-8", newline="\n")
        verify(ready)
        ready.rename(out)
    except Exception:
        shutil.rmtree(ready, ignore_errors=True)
        raise
    print("Prepared exact pinned offline Silero VAD bundle.")


if __name__ == "__main__":
    main()
