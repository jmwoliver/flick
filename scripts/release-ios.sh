#!/bin/bash
# Builds the iPhone app and uploads it to App Store Connect (it then appears in TestFlight,
# ready to submit for review).
#
#   scripts/release-ios.sh          # archive, check, and upload
#   scripts/release-ios.sh --dev    # local test: archive and check with development signing, no upload
#
# The version comes from MARKETING_VERSION in the project (change it in Xcode for each App Store
# version). The build number is the commit count, so every upload from a new commit is unique;
# set BUILD_NUMBER to override it.
#
# One-time setup: see "iPhone app" in docs/RELEASING.md (paid Apple Developer team in Xcode,
# and the app created in App Store Connect).

set -euo pipefail

MODE="${1:-}"
case "$MODE" in ""|--dev) ;; *) echo "Usage: scripts/release-ios.sh [--dev]" >&2; exit 1 ;; esac
DEV=false; [ "$MODE" = "--dev" ] && DEV=true

SCHEME="Flick"
PROJECT="Flick.xcodeproj"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build/release-ios"

setting() {
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' -v k="$1" '$1 ~ "^ *"k"$" {print $2; exit}'
}
VERSION="$(setting MARKETING_VERSION)"
TEAM_ID="$(setting DEVELOPMENT_TEAM)"
BUNDLE_ID="$(setting PRODUCT_BUNDLE_IDENTIFIER)"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
[ -n "$VERSION" ] && [ -n "$TEAM_ID" ] || fail "Couldn't read the version or team from the project."

if ! $DEV; then
  [ -z "$(git status --porcelain)" ] || fail "The working tree has uncommitted changes. Commit or stash them first."
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || fail "Release from the main branch."
  git fetch -q origin main
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main isn't in sync with origin/main. Push or pull first."
fi

say "Building Flick for iPhone $VERSION (build $BUILD_NUMBER), team $TEAM_ID$($DEV && echo ', dev mode')"
rm -rf "$BUILD"; mkdir -p "$BUILD"

say "Archiving..."
xcodebuild archive -quiet \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$BUILD/Flick.xcarchive" \
  -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  || fail "Archive failed."

# Check what App Review will look at.
say "Checking the build..."
APP="$BUILD/Flick.xcarchive/Products/Applications/Flick.app"
PLIST="$APP/Info.plist"
[ -f "$APP/PrivacyInfo.xcprivacy" ] || fail "PrivacyInfo.xcprivacy is missing from the app."
[ "$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")" = "$VERSION" ] || fail "Unexpected version in Info.plist."
[ "$(plutil -extract CFBundleVersion raw -o - "$PLIST")" = "$BUILD_NUMBER" ] || fail "Unexpected build number in Info.plist."
[ "$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")" = "$BUNDLE_ID" ] || fail "Unexpected bundle ID."
[ "$(plutil -extract ITSAppUsesNonExemptEncryption raw -o - "$PLIST")" = "false" ] || fail "ITSAppUsesNonExemptEncryption isn't set to NO."
[ "$(plutil -extract UIDeviceFamily json -o - "$PLIST")" = "[1]" ] || fail "Expected an iPhone-only app (UIDeviceFamily [1])."
for key in NSLocalNetworkUsageDescription NSBluetoothAlwaysUsageDescription NSBonjourServices; do
  plutil -extract "$key" raw -o - "$PLIST" >/dev/null 2>&1 || plutil -extract "$key" json -o - "$PLIST" >/dev/null 2>&1 \
    || fail "Info.plist is missing $key."
done

METHOD="app-store-connect"; DESTINATION="upload"
$DEV && { METHOD="debugging"; DESTINATION="export"; }
cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$METHOD</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

if $DEV; then
  say "Exporting with development signing (dev mode, no upload)..."
else
  say "Uploading to App Store Connect..."
fi
xcodebuild -exportArchive -quiet \
  -archivePath "$BUILD/Flick.xcarchive" \
  -exportOptionsPlist "$BUILD/ExportOptions.plist" \
  -exportPath "$BUILD/export" \
  -allowProvisioningUpdates \
  || fail "Export failed. If this is the first upload, check that the app exists in App Store Connect with bundle ID $BUNDLE_ID."

if $DEV; then
  say "Dev build exported to $BUILD/export. Nothing was uploaded."
  exit 0
fi

git tag -a "ios-$VERSION-$BUILD_NUMBER" -m "Flick for iPhone $VERSION ($BUILD_NUMBER)"
git push -q origin "ios-$VERSION-$BUILD_NUMBER"
say "Uploaded $VERSION ($BUILD_NUMBER). It shows up in App Store Connect › TestFlight after Apple processes it (usually 10–30 minutes)."
