#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/Native/SudachiBridge"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim
cargo build --release --target x86_64-apple-ios
mkdir -p target/universal-simulator
lipo -create target/aarch64-apple-ios-sim/release/libSudachiBridge.a \
  target/x86_64-apple-ios/release/libSudachiBridge.a -output target/universal-simulator/libSudachiBridge.a
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libSudachiBridge.a -headers include \
  -library target/universal-simulator/libSudachiBridge.a -headers include \
  -output "$ROOT/Native/SudachiBridge.xcframework"
echo "Next: attach the framework to the app target, and bundle Sudachi resources as described in README."
