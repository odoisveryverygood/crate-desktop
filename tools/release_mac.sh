#!/bin/bash
# Produce a notarized download from the already packaged Studio app.
set -euo pipefail
if [ "$#" -ne 4 ]; then
  echo "Usage: $0 CRATE.app 'Developer ID Application: Name (TEAM)' notary-profile output-directory" >&2
  exit 2
fi
app_source="$1"
release_identity="$2"
notary_profile="$3"
release_output="$4"
case "$release_identity" in
  "Developer ID Application:"*) ;;
  *) echo "A Developer ID Application signing identity is required." >&2; exit 2 ;;
esac
[ -d "$app_source/Contents/Resources/StudioLibrary" ] || { echo "Package the Studio library first." >&2; exit 2; }
mkdir -p "$release_output"
[ ! -e "$release_output/CRATE.app" ] && [ ! -e "$release_output/CRATE-Mac.zip" ] || { echo "Use an empty release output directory." >&2; exit 2; }
script_directory="$(cd "$(dirname "$0")" && pwd)"
ditto "$app_source" "$release_output/CRATE.app"
codesign --force --sign "$release_identity" --timestamp --options runtime --entitlements "$script_directory/../Resources/Mac.entitlements" "$release_output/CRATE.app"
codesign --verify --deep --strict "$release_output/CRATE.app"
ditto -c -k --sequesterRsrc --keepParent "$release_output/CRATE.app" "$release_output/CRATE-Mac-notary.zip"
xcrun notarytool submit "$release_output/CRATE-Mac-notary.zip" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$release_output/CRATE.app"
xcrun stapler validate "$release_output/CRATE.app"
spctl --assess --type execute --verbose "$release_output/CRATE.app"
ditto -c -k --sequesterRsrc --keepParent "$release_output/CRATE.app" "$release_output/CRATE-Mac.zip"
echo "Notarized download: $release_output/CRATE-Mac.zip"
