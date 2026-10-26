#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v python3.11 >/dev/null || { echo "Missing python3.11" >&2; exit 1; }
mkdir -p "$ROOT/BuildOutputs"
OUT="$ROOT/BuildOutputs/VAD"
if [[ -f "$OUT/asset-manifest.json" ]]; then
  python3.11 -B "$ROOT/Tools/vad_assets.py" "$OUT"
  echo "Existing verified bundled Silero VAD assets retained."
  exit 0
fi
if [[ -e "$OUT" ]]; then
  echo "Refusing incomplete/unverified VAD output: $OUT" >&2
  exit 1
fi
RUN="$(mktemp -d "$ROOT/BuildOutputs/vad-prep.XXXXXX")"
python3.11 -m venv "$RUN/python"
"$RUN/python/bin/python" -m pip install --disable-pip-version-check \
  -r "$ROOT/Tools/vad-requirements.txt" 2>&1 | tee "$RUN/install.log"
PYTHONPATH="$ROOT/Tools" "$RUN/python/bin/python" -B -u "$ROOT/Tools/prepare_vad_model.py" \
  --output "$OUT" 2>&1 | tee "$RUN/prepare.log"
python3.11 -B "$ROOT/Tools/vad_assets.py" "$OUT" 2>&1 | tee "$RUN/verify.log"
echo "Prepared exact pinned Silero VAD bundle for offline separator acceptance."
