#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
keychain="$HOME/Library/Keychains/sandbar-release.keychain-db"
identity="Developer ID Application"
profile=sandbar-notary

notarize() {
    answer=$(
        xcrun notarytool submit "$1" --keychain "$keychain" --keychain-profile "$profile" --wait --output-format json
    )
    if [ "$(printf '%s' "$answer" | plutil -extract status raw -o - -)" != Accepted ]; then
        xcrun notarytool log "$(printf '%s' "$answer" | plutil -extract id raw -o - -)" \
            --keychain "$keychain" --keychain-profile "$profile" >&2
        exit 1
    fi
}

security unlock-keychain -p "$(cat "$HOME/.config/sandbar-release/keychain-password")" "$keychain"
Scripts/build-app.sh
app=build/Sandbar.xcarchive/Products/Applications/Sandbar.app
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
image="build/Sandbar-$version.dmg"

codesign --force --options runtime --timestamp --keychain "$keychain" --sign "$identity" "$app"
ditto -c -k --keepParent "$app" build/app.zip
notarize build/app.zip
xcrun stapler staple -q "$app"  # the app opens offline once it is out of the image

mkdir build/image
ditto "$app" build/image/Sandbar.app
ln -s /Applications build/image/Applications
diskutil image create from --volumeName Sandbar build/image "$image"
codesign --timestamp --keychain "$keychain" --sign "$identity" "$image"
notarize "$image"
xcrun stapler staple -q "$image"
rm -r build/app.zip build/image

spctl --assess --type execute "$app"
spctl --assess --type open --context context:primary-signature "$image"
