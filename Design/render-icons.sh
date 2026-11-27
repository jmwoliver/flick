#!/bin/zsh
# Renders the master SVGs in this folder into the iOS and macOS asset catalogs.
# Needs rsvg-convert (brew install librsvg).
set -euo pipefail
cd "${0:A:h}"
IOS=../iOS/Assets.xcassets/AppIcon.appiconset
MAC=../Mac/Assets.xcassets/AppIcon.appiconset
BAR=../Mac/Assets.xcassets

rsvg-convert -w 1024 -h 1024 -b '#FACC15' flick-icon-ios.svg -o $IOS/AppIcon-1024.png
swift flatten.swift $IOS/AppIcon-1024.png
rsvg-convert -w 1024 -h 1024 flick-icon-ios-dark.svg   -o $IOS/AppIcon-1024-dark.png
rsvg-convert -w 1024 -h 1024 flick-icon-ios-tinted.svg -o $IOS/AppIcon-1024-tinted.png

for px in 16 32 64 128 256 512 1024; do
  src=flick-icon-mac.svg; (( px <= 32 )) && src=flick-icon-mac-small.svg
  rsvg-convert -w $px -h $px $src -o $MAC/icon_$px.png
done

cp menubar-connected.svg $BAR/MenuBarConnected.imageset/menubar-connected.svg
cp menubar-idle.svg      $BAR/MenuBarIdle.imageset/menubar-idle.svg
echo "Icons rendered."
