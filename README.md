# Sandbar

A Mac menu bar app: AI usage limits, pull requests waiting for your review, and your open pull requests.

Open `Sandbar.xcodeproj` in Xcode and press Run. `Scripts/check.sh` runs the formatter, every test and the app build; `Scripts/build-app.sh` makes `build/Sandbar-<version>-<build>.zip`.

`Scripts/build-image.sh` makes `build/Sandbar-<version>.dmg`, signed and notarized, and `Scripts/release.sh <notes file>` puts it up as a draft release. Both need the Developer ID certificate in `~/Library/Keychains/sandbar-release.keychain-db`, that keychain's password in `~/.config/sandbar-release/keychain-password` and a `notarytool` profile named `sandbar-notary` in the same keychain.
