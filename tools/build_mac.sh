#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=${CONFIGURATION:-Release}
build_root=${CRATE_MAC_BUILD_DIR:-build/mac}
xcodegen generate --spec mac-project.yml
xcodebuild -project CrateMac.xcodeproj -scheme CrateMac -configuration "$configuration" \
  -derivedDataPath "$build_root" CODE_SIGNING_ALLOWED=NO build
app_path="$build_root/Build/Products/$configuration/CRATE.app"
codesign --force --sign - --options runtime --entitlements Resources/Mac.entitlements "$app_path"
printf 'Built %s\n' "$app_path"
