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
# One-time setup (see docs/RELEASING.md):
#   - A "Developer ID Application" certificate in your keychain (Apple Developer Program).
#   - Notarization credentials saved as a keychain profile:
#       xcrun notarytool store-credentials flick-notary --apple-id <you@example.com> --team-id <TEAMID>
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

if ! $DEV; then
  [ -z "$(git status --porcelain)" ] || fail "The working tree has uncommitted changes. Commit or stash them first."
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || fail "Release from the main branch."
  git fetch -q origin main
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main isn't in sync with origin/main. Push or pull first."
  ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "Tag $TAG already exists."
  ! gh release view "$TAG" >/dev/null 2>&1 || fail "A GitHub release named $TAG already exists."
  security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($TEAM_ID)" \
    || fail "No 'Developer ID Application' certificate for team $TEAM_ID in your keychain. See docs/RELEASING.md."
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "No notarization credentials in keychain profile '$NOTARY_PROFILE'. See docs/RELEASING.md."
  gh auth status >/dev/null 2>&1 || fail "gh isn't signed in to GitHub. Run: gh auth login"
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
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  || fail "Archive failed."

say "Exporting and signing..."
METHOD="developer-id"; $DEV && METHOD="debugging"
cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$METHOD</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -quiet \
  -archivePath "$BUILD/Flick.xcarchive" \
  -exportOptionsPlist "$BUILD/ExportOptions.plist" \
  -exportPath "$BUILD/export" \
  -allowProvisioningUpdates \
  || fail "Export failed."
APP="$BUILD/export/Flick.app"
[ -d "$APP" ] || fail "Export didn't produce Flick.app."

# ── Check the build ─────────────────────────────────────────────────────────
say "Checking the signature..."
codesign --verify --deep --strict "$APP" || fail "Signature check failed."
SIG="$(codesign -dv --verbose=4 "$APP" 2>&1)"
grep -q "TeamIdentifier=$TEAM_ID" <<<"$SIG" || fail "Signed by the wrong team."
grep -q "flags=.*runtime" <<<"$SIG" || fail "Hardened Runtime is off; notarization would fail."
if ! $DEV; then
  grep -q "Authority=Developer ID Application" <<<"$SIG" || fail "Not signed with a Developer ID certificate."
  ! codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "get-task-allow" || fail "The app has the debugging entitlement (get-task-allow); notarization would fail."
fi
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Flick")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || fail "Expected a universal app (arm64 + x86_64), got: $ARCHS"
SHIPPED_VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
[ "$SHIPPED_VERSION" = "$VERSION" ] || fail "App reports version $SHIPPED_VERSION, expected $VERSION."

# ── Notarize ────────────────────────────────────────────────────────────────
zip_app() { rm -f "$DIST/$ASSET"; ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$ASSET"; }
if $DEV; then
  say "Skipping notarization (dev mode)."
else
  zip_app
  say "Notarizing (this usually takes a few minutes)..."
  xcrun notarytool submit "$DIST/$ASSET" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$BUILD/notary.json" \
    || fail "notarytool failed. See $BUILD/notary.json."
  STATUS="$(plutil -extract status raw -o - "$BUILD/notary.json")"
  if [ "$STATUS" != "Accepted" ]; then
    ID="$(plutil -extract id raw -o - "$BUILD/notary.json")"
    xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" "$BUILD/notary-log.json" || true
    fail "Notarization status: $STATUS. Apple's log: $BUILD/notary-log.json"
  fi
  say "Stapling the notarization ticket..."
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute -vv "$APP" 2>&1 | grep -q "source=Notarized Developer ID" || fail "Gatekeeper doesn't accept the app."
fi

# ── Package ─────────────────────────────────────────────────────────────────
zip_app   # zip again so the shipped archive contains the stapled ticket
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
