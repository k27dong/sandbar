#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift format lint --strict --recursive Package.swift Sources Tests Sandbar
swift test -j "${SANDBAR_JOBS:-3}"
if [ "$(uname)" = Darwin ]; then
    xcodebuild -project Sandbar.xcodeproj -scheme Sandbar -derivedDataPath .build/xcode build -quiet
fi
