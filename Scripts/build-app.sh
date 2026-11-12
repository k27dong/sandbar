#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
configuration="${1:-release}"
swift build -c "$configuration" --product Sandbar

app=build/Sandbar.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c "$configuration" --show-bin-path)/Sandbar" "$app/Contents/MacOS/Sandbar"
cp Sources/SandbarUI/Resources/Info.plist "$app/Contents/Info.plist"

icon=Sources/SandbarUI/Resources/AppIcon.png
iconset="$(mktemp -d)/AppIcon.iconset"
mkdir "$iconset"
for points in 16 32 128 256 512; do
    sips -z "$points" "$points" "$icon" --out "$iconset/icon_${points}x${points}.png" >/dev/null
    sips -z "$((points * 2))" "$((points * 2))" "$icon" --out "$iconset/icon_${points}x${points}@2x.png" >/dev/null
done
iconutil --convert icns --output "$app/Contents/Resources/AppIcon.icns" "$iconset"
rm -rf "$(dirname "$iconset")"

codesign --force --sign - "$app"
