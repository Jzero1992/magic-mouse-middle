#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="Magic Mouse 中键.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
icon_build="$(mktemp -d)"
trap 'rm -rf "$icon_build"' EXIT
mkdir "$icon_build/AppIcon.iconset"
xcrun swift make-icon.swift "$icon_build/AppIcon.iconset"
iconutil -c icns "$icon_build/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
xcrun clang -fobjc-arc -Wall -Wextra -Wno-unused-parameter -O2 -mmacosx-version-min=13.0 \
  -arch arm64 -arch x86_64 -framework AppKit -framework ApplicationServices \
  main.m -o "$app/Contents/MacOS/MagicMouseMiddle"
cp Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources/en.lproj"
cp en.lproj/Localizable.strings "$app/Contents/Resources/en.lproj/"

codesign --force --sign - "$app"
