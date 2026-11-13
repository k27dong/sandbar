#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
build=$(git rev-list --count HEAD)
rm -rf build
xcodebuild -project Sandbar.xcodeproj -scheme Sandbar -configuration Release -derivedDataPath .build/xcode \
    -archivePath build/Sandbar.xcarchive CURRENT_PROJECT_VERSION="$build" archive -quiet
app=build/Sandbar.xcarchive/Products/Applications/Sandbar.app
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
ditto -c -k --keepParent "$app" "build/Sandbar-$version-$build.zip"
