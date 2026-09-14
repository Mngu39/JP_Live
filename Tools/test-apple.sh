#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHASE="${1:-1}"
REQUESTED_PHASE="$PHASE"
case "$PHASE" in
  1) MIN_SDK=26 ;;
  1-trace) PHASE=1; MIN_SDK=26 ;;
  2) MIN_SDK=27 ;;
  *) echo "Usage: bash Tools/test-apple.sh [1|1-trace|2]" >&2; exit 2 ;;
esac
SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"
if [[ "${SDK_VERSION%%.*}" -lt "$MIN_SDK" ]]; then
  echo "Phase $PHASE requires iOS SDK $MIN_SDK or newer; selected SDK is $SDK_VERSION" >&2
  exit 1
fi
mkdir -p "$ROOT/BuildOutputs"
RUN="$(mktemp -d "$ROOT/BuildOutputs/phase${PHASE}.XXXXXX")"
# Keep both manifests and the failure log even when preflight stops the build.
cp "$ROOT/SHA256SUMS.txt" "$RUN/source-SHA256SUMS.original.txt"
python3 -B "$ROOT/Tools/source_checksums.py" normalize \
  "$ROOT/SHA256SUMS.txt" "$RUN/source-SHA256SUMS.txt"
(cd "$ROOT" && shasum -a 256 -c "$RUN/source-SHA256SUMS.txt") 2>&1 | tee "$RUN/checksums.log"
python3 -B "$ROOT/Tests/test_source_checksums.py" 2>&1 | tee "$RUN/checksum-tests.log"
PROJECT="$ROOT/Phase$PHASE/JPLive.xcodeproj"
RESOLVED="$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
# Evidence identifies the exact source and toolchain; a later ZIP cannot inherit it.
xcodebuild -version > "$RUN/toolchain.txt"
xcrun swift --version >> "$RUN/toolchain.txt"
xcrun --sdk iphonesimulator --show-sdk-version >> "$RUN/toolchain.txt"
xcrun simctl list devices available -j > "$RUN/simulators.json"
DESTINATION_ID="$(python3 "$ROOT/Tools/select-simulator.py" "$RUN/simulators.json" "$MIN_SDK")"
# macOS ships Bash 3.2: an empty array expanded under `set -u` is not portable.
run_xcodebuild() {
  if [[ "$PHASE" == 2 ]]; then
    # Noninteractive package-plugin approval for the preserved Phase 2 graph.
    if [[ -s "$RESOLVED" ]]; then
      xcodebuild "$@" -skipPackagePluginValidation -disableAutomaticPackageResolution
    else
      xcodebuild "$@" -skipPackagePluginValidation
    fi
  elif [[ "$REQUESTED_PHASE" == 1-trace ]]; then
    xcodebuild "$@" \
      -only-testing:JPLiveTests/AudioConversionTests/testDiagnosticSRCImpulseAlignment
  else
    xcodebuild "$@"
  fi
}
if [[ "$PHASE" == 2 ]]; then
  # Diagnostic only: establish whether ScreenCaptureKit is exposed by the
  # device SDK, simulator SDK, both, or neither before the app target compiles.
  # Do not alter the app source or hide the import based on this probe.
  {
    echo "=== ScreenCaptureKit SDK probe ==="
    echo "Xcode:"
    xcodebuild -version
    DEVICE_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
    SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
    echo "DEVICE_SDK=$DEVICE_SDK"
    echo "SIM_SDK=$SIM_SDK"
    echo "--- Framework paths ---"
    for sdk in "$DEVICE_SDK" "$SIM_SDK"; do
      framework="$sdk/System/Library/Frameworks/ScreenCaptureKit.framework"
      echo "SDK=$sdk"
      if [[ -d "$framework" ]]; then
        echo "framework=present"
        find "$framework" -maxdepth 3 -type f \( -name 'module.modulemap' -o -name '*.swiftinterface' -o -name '*.swiftmodule' \) -print | sort
      else
        echo "framework=missing"
      fi
    done

    PROBE_SWIFT="$RUN/ScreenCaptureKitProbe.swift"
    printf 'import ScreenCaptureKit\n' > "$PROBE_SWIFT"

    echo "--- device swiftc import probe ---"
    set +e
    xcrun --sdk iphoneos swiftc \
      -target arm64-apple-ios27.0 \
      -sdk "$DEVICE_SDK" \
      -typecheck "$PROBE_SWIFT"
    DEVICE_PROBE_STATUS=$?
    set -e
    echo "device_probe_status=$DEVICE_PROBE_STATUS"

    echo "--- simulator swiftc import probe ---"
    set +e
    xcrun --sdk iphonesimulator swiftc \
      -target arm64-apple-ios27.0-simulator \
      -sdk "$SIM_SDK" \
      -typecheck "$PROBE_SWIFT"
    SIM_PROBE_STATUS=$?
    set -e
    echo "simulator_probe_status=$SIM_PROBE_STATUS"

    echo "--- relevant app build settings: generic iOS ---"
    run_xcodebuild -project "$PROJECT" -scheme JPLive -configuration Debug \
      -destination 'generic/platform=iOS' -showBuildSettings 2>/dev/null \
      | grep -E '^[[:space:]]*(SDKROOT|SUPPORTED_PLATFORMS|PLATFORM_NAME|EFFECTIVE_PLATFORM_NAME|ARCHS|VALID_ARCHS|SWIFT_ACTIVE_COMPILATION_CONDITIONS|IPHONEOS_DEPLOYMENT_TARGET)[[:space:]]*=' || true

    echo "--- relevant app build settings: selected simulator ---"
    run_xcodebuild -project "$PROJECT" -scheme JPLive -configuration Debug \
      -destination "platform=iOS Simulator,id=$DESTINATION_ID" -showBuildSettings 2>/dev/null \
      | grep -E '^[[:space:]]*(SDKROOT|SUPPORTED_PLATFORMS|PLATFORM_NAME|EFFECTIVE_PLATFORM_NAME|ARCHS|VALID_ARCHS|SWIFT_ACTIVE_COMPILATION_CONDITIONS|IPHONEOS_DEPLOYMENT_TARGET)[[:space:]]*=' || true
    echo "=== End ScreenCaptureKit SDK probe ==="
  } 2>&1 | tee "$RUN/screencapturekit-probe.log"

  run_xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme JPLive 2>&1 | tee "$RUN/resolve.log"
  test -s "$RESOLVED"
  cp "$RESOLVED" "$RUN/Package.resolved"
fi
run_xcodebuild -project "$PROJECT" -scheme JPLive -configuration Debug \
  -destination "platform=iOS Simulator,id=$DESTINATION_ID" \
  -derivedDataPath "$RUN/DerivedData" -resultBundlePath "$RUN/tests.xcresult" \
  -parallel-testing-enabled NO test CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$RUN/tests.log"
if [[ "$REQUESTED_PHASE" == 1-trace ]]; then
  echo "DIAGNOSTIC ONLY: SRC impulse-alignment probe; not full validation or a device-build pass."
  exit 0
fi
run_xcodebuild -project "$PROJECT" -scheme JPLive -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$RUN/DeviceDerivedData" build CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$RUN/device-build.log"
if [[ "$PHASE" == 2 ]]; then cmp "$RESOLVED" "$RUN/Package.resolved"; fi
echo "PASS: Phase $PHASE Apple compile, simulator XCTest, unsigned device build" | tee "$RUN/PASS.txt"
echo "Evidence: $RUN"
echo "This does not certify iPad Playground packaging or live STT/Translation/capture."
