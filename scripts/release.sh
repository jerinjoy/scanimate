#!/bin/bash
# Builds an ad-hoc signed, universal Release build of Scanimate and zips it
# for a GitHub Release. The build is not notarized, so Gatekeeper blocks it on
# first launch (see "Install" in the README).
#
# Usage: scripts/release.sh
# Output: build/Scanimate-<version>.zip
set -euo pipefail

cd "$(dirname "$0")/.."

# xcodebuild needs the full Xcode, not the Command Line Tools.
if ! xcodebuild -version >/dev/null 2>&1; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Scanimate/Info.plist)
derived=build/DerivedData
app="$derived/Build/Products/Release/Scanimate.app"
zip="build/Scanimate-$version.zip"

xcodegen generate --quiet

# Ad-hoc signing ("-") needs no Apple Developer account, and keeps the
# sandbox entitlements. Apple silicon refuses to run unsigned code at all.
xcodebuild \
    -project Scanimate.xcodeproj \
    -scheme Scanimate \
    -configuration Release \
    -derivedDataPath "$derived" \
    -destination "generic/platform=macOS" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    clean build

codesign --verify --deep --strict "$app"

rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

echo
echo "Built $zip"
echo "  architectures: $(lipo -archs "$app/Contents/MacOS/Scanimate")"
echo "  sha256:        $(shasum -a 256 "$zip" | cut -d' ' -f1)"
