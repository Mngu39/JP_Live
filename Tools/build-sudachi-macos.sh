#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for tool in cargo rustup python3 xcodebuild lipo; do
  command -v "$tool" >/dev/null || { echo "Missing $tool: native Sudachi requires macOS Rust/Xcode/Python." >&2; exit 1; }
done
python3 -c 'import sys; sys.exit("Sudachi resource preparation requires Python 3.10 or newer") if sys.version_info < (3, 10) else None'
mkdir -p "$ROOT/BuildOutputs"
STAGE="$(mktemp -d "$ROOT/BuildOutputs/sudachi-stage.XXXXXX")"
cp -R "$ROOT/Native/SudachiBridge" "$STAGE/Bridge"
# Generated dependency locks and compiler outputs stay outside checksummed source.
python3 -m venv "$STAGE/python"
"$STAGE/python/bin/python" -m pip install --disable-pip-version-check 'SudachiPy==0.6.11' 'SudachiDict-full==20260723'
"$STAGE/python/bin/python" "$ROOT/Tools/prepare-sudachi-resources.py" "$STAGE/Resources/Sudachi"
cd "$STAGE/Bridge"
cargo generate-lockfile
JP_SUDACHI_TEST_RESOURCES="$STAGE/Resources/Sudachi" cargo test --locked --release
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
cargo build --locked --release --target aarch64-apple-ios
cargo build --locked --release --target aarch64-apple-ios-sim
cargo build --locked --release --target x86_64-apple-ios
mkdir -p target/universal-simulator
lipo -create target/aarch64-apple-ios-sim/release/libSudachiBridge.a \
  target/x86_64-apple-ios/release/libSudachiBridge.a -output target/universal-simulator/libSudachiBridge.a
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libSudachiBridge.a -headers include \
  -library target/universal-simulator/libSudachiBridge.a -headers include \
  -output "$STAGE/SudachiBridge.xcframework"
mkdir -p "$STAGE/Ready"
mv "$STAGE/SudachiBridge.xcframework" "$STAGE/Ready/"
mv "$STAGE/Resources" "$STAGE/Ready/"
cp Cargo.lock "$STAGE/Ready/Cargo.lock"
# Publish a complete bundle; preserve older generated output, never source inputs.
if [[ -e "$ROOT/BuildOutputs/Sudachi" ]]; then
  mv "$ROOT/BuildOutputs/Sudachi" "$STAGE/Previous"
fi
mv "$STAGE/Ready" "$ROOT/BuildOutputs/Sudachi"
echo "Prepared: BuildOutputs/Sudachi (framework, full dictionary, license evidence, asset hashes, Cargo.lock)"
echo "Phase 2 links and bundles these files; Phase 1 stays dependency-free."
