#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
if [[ "${SDK_VERSION%%.*}" -lt 27 ]]; then
  echo "Xcode with the iOS 27 SDK is required. Current SDK: $SDK_VERSION" >&2
  exit 1
fi
# IPA creation must not be the first Apple compile/test of this source revision.
bash "$ROOT/Tools/test-apple.sh" 2
mkdir -p "$ROOT/work/build" "$ROOT/BuildOutputs"
BUILD_ROOT="$(mktemp -d "$ROOT/work/build/archive.XXXXXX")"
RESOLVED="$ROOT/Phase2/JPLive.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
if [[ -s "$RESOLVED" ]]; then
  xcodebuild -resolvePackageDependencies -project "$ROOT/Phase2/JPLive.xcodeproj" -scheme JPLive -disableAutomaticPackageResolution
else
  xcodebuild -resolvePackageDependencies -project "$ROOT/Phase2/JPLive.xcodeproj" -scheme JPLive
fi
if [[ ! -s "$RESOLVED" ]]; then
  echo "Package resolution did not produce $RESOLVED; preserve the resolver error before continuing." >&2
  exit 1
fi
cp "$RESOLVED" "$BUILD_ROOT/Package.resolved"
cp "$RESOLVED" "$ROOT/BuildOutputs/Package.resolved"
xcodebuild -project "$ROOT/Phase2/JPLive.xcodeproj" -scheme JPLive \
  -disableAutomaticPackageResolution \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$BUILD_ROOT/JPLive.xcarchive" archive CODE_SIGNING_ALLOWED=NO
if ! cmp -s "$RESOLVED" "$BUILD_ROOT/Package.resolved"; then
  echo "Package.resolved changed during archive; review dependency changes before packaging an IPA." >&2
  exit 1
fi
APP="$BUILD_ROOT/JPLive.xcarchive/Products/Applications/JPLive.app"
test -d "$APP"
mkdir -p "$BUILD_ROOT/Payload"
ditto "$APP" "$BUILD_ROOT/Payload/JPLive.app"
(cd "$BUILD_ROOT" && /usr/bin/zip -qry JPLive-unsigned.ipa Payload)
mv -f "$BUILD_ROOT/JPLive-unsigned.ipa" "$ROOT/BuildOutputs/JPLive-unsigned.ipa"
echo "Built: $ROOT/BuildOutputs/JPLive-unsigned.ipa"
echo "Unsigned: install through a signing workflow such as SideStore. This script does not deploy anything."
