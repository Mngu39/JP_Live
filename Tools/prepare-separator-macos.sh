#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "Separator conversion/parity requires macOS with Xcode; no model was generated." >&2
  exit 1
fi
for tool in python3.11 xcrun; do
  command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }
done
mkdir -p "$ROOT/BuildOutputs"
if [[ -d "$ROOT/BuildOutputs/Separation" ]] && [[ -n "$(ls -A "$ROOT/BuildOutputs/Separation")" ]]; then
  python3.11 -B "$ROOT/Tools/separator_assets.py" "$ROOT/BuildOutputs/Separation"
  echo "Existing verified conversion assets retained; Japanese/device validation is still required."
  exit 0
fi
RUN="$(mktemp -d "$ROOT/BuildOutputs/separator-export.XXXXXX")"
python3.11 -m venv "$RUN/python"
"$RUN/python/bin/python" -m pip install --disable-pip-version-check \
  -r "$ROOT/Tools/separator-requirements.txt" 2>&1 | tee "$RUN/install.log"
"$RUN/python/bin/python" -B -u "$ROOT/Tools/export_separator.py" \
  --output "$RUN/Separator.mlpackage" \
  --cache "$ROOT/BuildOutputs/separator-source" \
  --app-resources "$ROOT/BuildOutputs/Separation" 2>&1 | tee "$RUN/export.log"
"$RUN/python/bin/python" -B "$ROOT/Tools/separator_assets.py" "$ROOT/BuildOutputs/Separation" \
  2>&1 | tee "$RUN/assets.log"
echo "Prepared conversion assets. Next: Apple compile/XCTest and actual Japanese/iPad validation."
