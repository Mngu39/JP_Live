"""Dependency-free verification for the pinned bundled LS-EEND model."""
from pathlib import Path, PurePosixPath
import argparse, hashlib, json, re

MODEL = "FluidInference/ls-eend-coreml"
REVISION = "62e09c20262f7c7406c7a5e70755e9f957ef09ac"
FLUID_AUDIO_REVISION = "5c19d5e12320e22bbfb7a1877b089d2665a69add"
MODEL_PREFIX = "LSEEND/ls_eend_dih3_100ms.mlmodelc/"

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
            raise ValueError("Diarizer assets must not contain symbolic links")
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
        "fluidAudioRevision": FLUID_AUDIO_REVISION,
        "variant": "dihard3",
        "step": "100ms",
        "sampleRate": 8000,
        "runtimePolicy": "bundled-offline-only",
    }
    for key, value in expected.items():
        if manifest.get(key) != value:
            raise ValueError(f"Diarizer manifest mismatch: {key}")
    records = manifest.get("sha256")
    if not isinstance(records, dict) or not records:
        raise ValueError("Missing diarizer asset hashes")
    for name, digest in records.items():
        path = PurePosixPath(name)
        if (path.is_absolute() or ".." in path.parts or name != path.as_posix()
                or any(c in name for c in "\\\r\n\x00:")
                or not isinstance(digest, str)
                or re.fullmatch(r"[0-9a-f]{64}", digest) is None):
            raise ValueError("Invalid diarizer manifest entry")
    if not any(name.startswith(MODEL_PREFIX) for name in records):
        raise ValueError("Bundled LS-EEND mlmodelc missing")
    for required in ("licenses/MIT.txt", "source.json"):
        if required not in records:
            raise ValueError("Diarizer provenance/license evidence missing: " + required)
    source = json.loads((directory / "source.json").read_text(encoding="utf-8"))
    for key in ("source", "revision", "fluidAudioRevision", "variant", "step", "sampleRate"):
        if source.get(key) != manifest.get(key):
            raise ValueError("Diarizer source metadata mismatch: " + key)
    if source.get("runtimePolicy") != "bundled-offline-only; no runtime network fallback":
        raise ValueError("Diarizer source runtime policy mismatch")
    if asset_hashes(directory) != records:
        raise ValueError("Diarizer file contents/list differ from manifest")
    return {"status": "BUNDLED_LSEEND_VERIFIED", "files": len(records), "revision": REVISION}

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.directory), indent=2))
