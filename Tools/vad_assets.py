"""Dependency-free verification for the pinned bundled Silero VAD Core ML model."""
from pathlib import Path, PurePosixPath
import argparse, hashlib, json, re

MODEL = "FluidInference/silero-vad-coreml"
REVISION = "b419383c55c110e2c9271fa6ee0ea83d03c70d96"
MODEL_DIR = "silero-vad-unified-256ms-v6.2.1.mlmodelc"
MODEL_PREFIX = MODEL_DIR + "/"


def file_hash(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def asset_hashes(directory):
    directory = Path(directory)
    result = {}
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise ValueError("VAD assets must not contain symbolic links")
        if path.is_file() and path != directory / "asset-manifest.json":
            result[path.relative_to(directory).as_posix()] = file_hash(path)
    return result


def verify(directory):
    directory = Path(directory)
    manifest = json.loads((directory / "asset-manifest.json").read_text(encoding="utf-8"))
    expected = {
        "schemaVersion": 1,
        "source": MODEL,
        "revision": REVISION,
        "license": "MIT",
        "variant": "silero-vad-unified-256ms-v6.2.1",
        "sampleRate": 16000,
        "chunkSize": 4096,
        "runtimePolicy": "bundled-offline-only",
    }
    for key, value in expected.items():
        if manifest.get(key) != value:
            raise ValueError(f"VAD manifest mismatch: {key}")
    records = manifest.get("sha256")
    if not isinstance(records, dict) or not records:
        raise ValueError("Missing VAD asset hashes")
    for name, digest in records.items():
        path = PurePosixPath(name)
        if (path.is_absolute() or ".." in path.parts or name != path.as_posix()
                or any(c in name for c in "\\\r\n\x00:")
                or not isinstance(digest, str)
                or re.fullmatch(r"[0-9a-f]{64}", digest) is None):
            raise ValueError("Invalid VAD manifest entry")
    if not any(name.startswith(MODEL_PREFIX) for name in records):
        raise ValueError("Bundled Silero VAD mlmodelc missing")
    for required in ("licenses/MIT.txt", "licenses/model-card.md", "source.json"):
        if required not in records:
            raise ValueError("VAD provenance/license evidence missing: " + required)
    source = json.loads((directory / "source.json").read_text(encoding="utf-8"))
    for key in ("source", "revision", "variant", "sampleRate", "chunkSize"):
        if source.get(key) != manifest.get(key):
            raise ValueError("VAD source metadata mismatch: " + key)
    if source.get("runtimePolicy") != "bundled-offline-only; no runtime network fallback":
        raise ValueError("VAD source runtime policy mismatch")
    if asset_hashes(directory) != records:
        raise ValueError("VAD file contents/list differ from manifest")
    return {"status": "BUNDLED_SILERO_VAD_VERIFIED", "files": len(records), "revision": REVISION}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.directory), indent=2))
