#!/bin/bash
# Builds, signs, notarizes and publishes Flick for Mac as a GitHub release.
#
#   scripts/release-mac.sh 0.2.0             # draft release (review it on GitHub, then publish)
#   scripts/release-mac.sh 0.2.0 --publish   # publish right away
#   scripts/release-mac.sh 0.2.0 --dev       # local test: Apple Development signing, no
#                                            # notarization, no GitHub release
#
# Output, in dist/:
#   Flick-macOS.zip          the notarized, stapled app (what website/install.sh downloads)
#   Flick-macOS.zip.sha256   its checksum, in `shasum -a 256` format
#
# Requirements (see docs/RELEASING.md):
#   - Xcode signed in to an Apple ID on a paid Apple Developer Program team. Xcode creates the
#     Developer ID certificate itself, and notarizes with that account.
#   - Optional: notarytool credentials saved as the keychain profile "flick-notary". If present,
#     they're used for notarization instead of the Xcode account.
#   - `gh` signed in to GitHub with access to the repo.

set -euo pipefail

VERSION="${1:-}"
MODE="${2:-}"
SCHEME="FlickMac"
PROJECT="Flick.xcodeproj"
ASSET="Flick-macOS.zip"
NOTARY_PROFILE="${FLICK_NOTARY_PROFILE:-flick-notary}"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Usage: scripts/release-mac.sh <major.minor.patch> [--publish|--dev]"
case "$MODE" in ""|--publish|--dev) ;; *) fail "Unknown option '$MODE'. Use --publish or --dev." ;; esac
DEV=false; [ "$MODE" = "--dev" ] && DEV=true

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build/release"
DIST="$ROOT/dist"
TAG="v$VERSION"

# ── Preflight ───────────────────────────────────────────────────────────────
TEAM_ID="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/^ *DEVELOPMENT_TEAM = /{print $2; exit}')"
[ -n "$TEAM_ID" ] || fail "Couldn't read DEVELOPMENT_TEAM from the project."

USE_NOTARYTOOL=false
if ! $DEV; then
  [ -z "$(git status --porcelain)" ] || fail "The working tree has uncommitted changes. Commit or stash them first."
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || fail "Release from the main branch."
  git fetch -q origin main
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main isn't in sync with origin/main. Push or pull first."
  ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "Tag $TAG already exists."
  ! gh release view "$TAG" >/dev/null 2>&1 || fail "A GitHub release named $TAG already exists."
  gh auth status >/dev/null 2>&1 || fail "gh isn't signed in to GitHub. Run: gh auth login"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 && USE_NOTARYTOOL=true
fi

# The installer refuses apps from any other team, so a mismatch would ship a release nobody can install.
INSTALL_TEAM="$(sed -n 's/^TEAM_ID="\(.*\)"$/\1/p' website/install.sh)"
[ "$INSTALL_TEAM" = "$TEAM_ID" ] || fail "website/install.sh expects team '$INSTALL_TEAM' but the app is signed by '$TEAM_ID'. Update TEAM_ID in install.sh (and deploy the site) first."

BUILD_NUMBER="$(git rev-list --count HEAD)"
say "Releasing Flick for Mac $VERSION (build $BUILD_NUMBER), team $TEAM_ID$($DEV && echo ', dev mode')"

rm -rf "$BUILD" "$DIST"
mkdir -p "$BUILD" "$DIST"

# ── Build ───────────────────────────────────────────────────────────────────
say "Archiving..."
xcodebuild archive -quiet \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$BUILD/Flick.xcarchive" \
  -allowProvisioningUpdates \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  || fail "Archive failed."

export_options() {  # method, destination
  cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$1</string>
  <key>destination</key><string>$2</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
}
export_archive() {
  xcodebuild -exportArchive -quiet \
    -archivePath "$BUILD/Flick.xcarchive" \
    -exportOptionsPlist "$BUILD/ExportOptions.plist" \
    -exportPath "$1" \
    -allowProvisioningUpdates
}
NOT_PAID="Developer ID signing failed. It needs a paid Apple Developer Program team selected in the project, with Xcode signed in to it (Settings › Accounts)."

# Checks that the app is what we mean to ship. Run before notarizing when we can, and on the final app.
check_app() {
  local app="$1"
  codesign --verify --deep --strict "$app" || fail "Signature check failed."
  local sig; sig="$(codesign -dv --verbose=4 "$app" 2>&1)"
  grep -q "TeamIdentifier=$TEAM_ID" <<<"$sig" || fail "Signed by the wrong team."
  grep -q "flags=.*runtime" <<<"$sig" || fail "Hardened Runtime is off; notarization would fail."
  if ! $DEV; then
    grep -q "Authority=Developer ID Application" <<<"$sig" || fail "Not signed with a Developer ID certificate."
    ! codesign -d --entitlements - "$app" 2>/dev/null | grep -q "get-task-allow" || fail "The app has the debugging entitlement (get-task-allow); notarization would fail."
  fi
  local archs; archs="$(lipo -archs "$app/Contents/MacOS/Flick")"
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "Expected a universal app (arm64 + x86_64), got: $archs"
  [ "$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString)" = "$VERSION" ] || fail "The app reports the wrong version."
}

zip_app() { rm -f "$DIST/$ASSET"; ditto -c -k --sequesterRsrc --keepParent "$1" "$DIST/$ASSET"; }

# ── Sign and notarize ───────────────────────────────────────────────────────
if $DEV; then
  say "Exporting with development signing..."
  export_options debugging export
  export_archive "$BUILD/export" || fail "Export failed."
  APP="$BUILD/export/Flick.app"
  say "Checking the app..."; check_app "$APP"
  say "Skipping notarization (dev mode)."

elif $USE_NOTARYTOOL; then
  say "Exporting with Developer ID..."
  export_options developer-id export
  export_archive "$BUILD/export" || fail "$NOT_PAID"
  APP="$BUILD/export/Flick.app"
  say "Checking the app..."; check_app "$APP"
  zip_app "$APP"
  say "Notarizing with notarytool profile '$NOTARY_PROFILE' (usually a few minutes)..."
  xcrun notarytool submit "$DIST/$ASSET" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$BUILD/notary.json" \
    || fail "notarytool failed. See $BUILD/notary.json."
  STATUS="$(plutil -extract status raw -o - "$BUILD/notary.json")"
  if [ "$STATUS" != "Accepted" ]; then
    ID="$(plutil -extract id raw -o - "$BUILD/notary.json")"
    xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" "$BUILD/notary-log.json" || true
    fail "Notarization status: $STATUS. Apple's log: $BUILD/notary-log.json"
  fi
  xcrun stapler staple "$APP"

else
  # Xcode signs with Developer ID and submits to Apple's notary service with its signed-in
  # account, then hands back the notarized, stapled app.
  say "Signing with Developer ID and submitting for notarization with your Xcode account..."
  export_options developer-id upload
  export_archive "$BUILD/submitted" || fail "$NOT_PAID"
  say "Waiting for Apple's notary service (usually a few minutes, checking every 30 s)..."
  for i in $(seq 1 60); do
    if xcodebuild -exportNotarizedApp -archivePath "$BUILD/Flick.xcarchive" -exportPath "$BUILD/notarized" > "$BUILD/notarized.log" 2>&1 \
       && [ -d "$BUILD/notarized/Flick.app" ]; then
      break
    fi
    grep -qiE "invalid|rejected" "$BUILD/notarized.log" && fail "Apple rejected the app. Details: $BUILD/notarized.log"
    [ "$i" = 60 ] && fail "Notarization didn't finish within 30 minutes. Last status: $BUILD/notarized.log"
    sleep 30
  done
  APP="$BUILD/notarized/Flick.app"
  say "Checking the app..."; check_app "$APP"
fi

if ! $DEV; then
  xcrun stapler validate "$APP" >/dev/null || fail "The app has no stapled notarization ticket."
  spctl --assess --type execute -vv "$APP" 2>&1 | grep -q "source=Notarized Developer ID" || fail "Gatekeeper doesn't accept the app."
  say "Notarized and accepted by Gatekeeper."
fi

# ── Package ─────────────────────────────────────────────────────────────────
zip_app "$APP"   # the shipped zip contains the stapled ticket
(cd "$DIST" && shasum -a 256 "$ASSET" > "$ASSET.sha256")
say "Built $DIST/$ASSET ($(du -h "$DIST/$ASSET" | cut -f1)), sha256 $(cut -d' ' -f1 "$DIST/$ASSET.sha256")"

if $DEV; then
  say "Dev build done. Nothing was notarized or published."
  exit 0
fi

# ── Publish ─────────────────────────────────────────────────────────────────
say "Creating GitHub release $TAG..."
git tag -a "$TAG" -m "Flick for Mac $VERSION"
git push -q origin "$TAG"
DRAFT="--draft"; [ "$MODE" = "--publish" ] && DRAFT=""
gh release create "$TAG" "$DIST/$ASSET" "$DIST/$ASSET.sha256" \
  --title "Flick $VERSION" --generate-notes --verify-tag $DRAFT
if [ -n "$DRAFT" ]; then
  say "Draft release created. Review it, then publish it on GitHub; install.sh only sees published releases."
else
  say "Published. Anyone can now install it with: curl -fsSL https://getflick.net/install.sh | bash"
fi
