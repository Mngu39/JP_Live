#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v python3.11 >/dev/null || { echo "Missing python3.11" >&2; exit 1; }
mkdir -p "$ROOT/BuildOutputs"
OUT="$ROOT/BuildOutputs/Diarization"
if [[ -f "$OUT/asset-manifest.json" ]]; then
  python3.11 -B "$ROOT/Tools/diarizer_assets.py" "$OUT"
  echo "Existing verified bundled LS-EEND assets retained."
  exit 0
fi
if [[ -e "$OUT" ]]; then
  echo "Refusing incomplete/unverified diarizer output: $OUT" >&2
  exit 1
fi
RUN="$(mktemp -d "$ROOT/BuildOutputs/diarizer-prep.XXXXXX")"
python3.11 -m venv "$RUN/python"
"$RUN/python/bin/python" -m pip install --disable-pip-version-check \
  -r "$ROOT/Tools/diarizer-requirements.txt" 2>&1 | tee "$RUN/install.log"
PYTHONPATH="$ROOT/Tools" "$RUN/python/bin/python" -B -u "$ROOT/Tools/prepare_diarizer_model.py" \
  --output "$OUT" 2>&1 | tee "$RUN/prepare.log"
python3.11 -B "$ROOT/Tools/diarizer_assets.py" "$OUT" 2>&1 | tee "$RUN/verify.log"
echo "Prepared exact pinned LS-EEND bundle for offline/runtime-network-free diarization."
