#!/bin/bash
# Installs Flick for Mac from the latest release on GitHub.
#
#   curl -fsSL https://getflick.net/install.sh | bash
#
# What it does:
#   1. Downloads Flick-macOS.zip and its SHA-256 checksum from the latest GitHub release.
#   2. Checks the checksum, and that the app is signed by Flick's developer (team ID below).
#   3. Quits Flick if it's running, replaces /Applications/Flick.app, and opens it.
#
# Source: https://github.com/jmwoliver/flick

set -euo pipefail

REPO="jmwoliver/flick"
ASSET="Flick-macOS.zip"
# Apple Developer team that signs Flick. The install stops if the app is signed by anyone else.
TEAM_ID="F9UPC9VN4S"
BUNDLE_ID="com.jacobwoliver.flick.mac"
DEST="/Applications/Flick.app"
MIN_MACOS=14

# Everything runs inside main(), so a partly downloaded script does nothing.
main() {
  say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
  fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

  [ "$(uname -s)" = "Darwin" ] || fail "Flick for Mac only runs on macOS."
  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  [ "$major" -ge "$MIN_MACOS" ] || fail "Flick needs macOS $MIN_MACOS or later (this Mac has $(sw_vers -productVersion))."

  # Global (not local) so the EXIT trap can still see it after main returns.
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  local base="https://github.com/$REPO/releases/latest/download"
  say "Downloading Flick..."
  if ! curl -fsSL -o "$tmp/$ASSET" "$base/$ASSET"; then
    fail "Couldn't download Flick. There may not be a release yet; see https://github.com/$REPO/releases, or build it from source: https://github.com/$REPO#build-from-source"
  fi
  curl -fsSL -o "$tmp/$ASSET.sha256" "$base/$ASSET.sha256" || fail "Couldn't download the checksum for $ASSET."

  say "Checking the download..."
  local expected actual
  expected="$(awk '{print $1}' "$tmp/$ASSET.sha256")"
  actual="$(shasum -a 256 "$tmp/$ASSET" | awk '{print $1}')"
  [ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "Checksum mismatch. The download may be corrupted; nothing was installed."

  ditto -x -k "$tmp/$ASSET" "$tmp/unzipped" || fail "Couldn't unzip $ASSET."
  local app="$tmp/unzipped/Flick.app"
  [ -d "$app" ] || fail "The download doesn't contain Flick.app."

  codesign --verify --deep --strict "$app" 2>/dev/null || fail "Flick.app's code signature is invalid; nothing was installed."
  local team id
  team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  id="$(codesign -dv "$app" 2>&1 | sed -n 's/^Identifier=//p')"
  [ "$team" = "$TEAM_ID" ] || fail "Flick.app is signed by an unexpected developer (team '$team'); nothing was installed."
  [ "$id" = "$BUNDLE_ID" ] || fail "Unexpected app identifier '$id'; nothing was installed."

  if pgrep -xq Flick; then
    say "Quitting the running copy of Flick..."
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    sleep 1
  fi

  say "Installing to $DEST..."
  local sudo=""
  [ -w "$(dirname "$DEST")" ] && { [ ! -e "$DEST" ] || [ -w "$DEST" ]; } || sudo="sudo"
  [ -n "$sudo" ] && say "Your password is needed to write to /Applications."
  $sudo rm -rf "$DEST"
  $sudo ditto "$app" "$DEST"

  open "$DEST"
  say "Flick is installed and running. Look for its icon in the menu bar."
  echo
  echo "Next:"
  echo "  1. Allow Local Network access when macOS asks."
  echo "  2. Turn on Flick in System Settings > Privacy & Security > Accessibility."
  echo "  3. Open Flick on your iPhone, tap this Mac, and enter the PIN from the menu bar."
}

main "$@"
