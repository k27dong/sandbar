#!/bin/sh
set -eu
notes=${1:?usage: Scripts/release.sh <file with the release notes>}
notes=$(cd "$(dirname "$notes")" && pwd)/$(basename "$notes")
cd "$(dirname "$0")/.."
if [ ! -s "$notes" ]; then
    echo "$notes has no release notes." >&2
    exit 1
fi
git fetch --quiet origin master
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/master)" ]; then
    echo "A release is made from a clean checkout of origin/master." >&2
    exit 1
fi
version=$(xcodebuild -project Sandbar.xcodeproj -scheme Sandbar -showBuildSettings 2>/dev/null |
    awk '/ MARKETING_VERSION = / { print $3 }')
if gh release view "v${version:?the project names no version}" >/dev/null 2>&1; then
    echo "v$version is released already: raise MARKETING_VERSION first." >&2
    exit 1
fi

Scripts/build-image.sh
gh release create "v$version" "build/Sandbar-$version.dmg" --draft --title "Sandbar $version" \
    --notes-file "$notes" --target "$(git rev-parse HEAD)"
