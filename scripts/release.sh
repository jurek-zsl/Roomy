#!/bin/bash
# Build Roomy, sign it with a Developer ID, notarize it and pack a DMG.
#
#   ROOMY_SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   ROOMY_NOTARY_PROFILE=notary  scripts/release.sh
#
# The notary profile is one you stored with `xcrun notarytool store-credentials`.
# Output: dist/Roomy.app and dist/Roomy-<version>.dmg
set -euo pipefail
: "${ROOMY_SIGNING_IDENTITY:?set ROOMY_SIGNING_IDENTITY to your Developer ID Application identity}"
PROFILE="${ROOMY_NOTARY_PROFILE:-notary}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/app"
xcodegen generate >/dev/null
xcodebuild build -project Roomy.xcodeproj -scheme Roomy -configuration Release -derivedDataPath build -quiet
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/Build/Products/Release/Roomy.app/Contents/Info.plist)"
dist="$root/dist"
rm -rf "$dist" && mkdir -p "$dist"
ditto build/Build/Products/Release/Roomy.app "$dist/Roomy.app"

notarize() { # path
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$2"
}
sign() { codesign --force --options runtime --timestamp --sign "$ROOMY_SIGNING_IDENTITY" "$@"; }
# Inside out: Sparkle's helpers, the engine, then the app, with the hardened runtime.
sparkle="$dist/Roomy.app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$sparkle/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
sign "$dist/Roomy.app/Contents/Frameworks/Sparkle.framework"
sign "$dist/Roomy.app/Contents/MacOS/roomy-engine"
codesign --force --options runtime --timestamp --sign "$ROOMY_SIGNING_IDENTITY" "$dist/Roomy.app"
codesign --verify --deep --strict "$dist/Roomy.app"
ditto -c -k --keepParent "$dist/Roomy.app" "$dist/Roomy.zip"
notarize "$dist/Roomy.zip" "$dist/Roomy.app"
rm "$dist/Roomy.zip"

stage="$(mktemp -d)"
ditto "$dist/Roomy.app" "$stage/Roomy.app"
ln -s /Applications "$stage/Applications"
dmg="$dist/Roomy-$version.dmg"
hdiutil create -volname Roomy -srcfolder "$stage" -ov -format UDZO "$dmg" -quiet
rm -rf "$stage"
codesign --force --timestamp --sign "$ROOMY_SIGNING_IDENTITY" "$dmg"
notarize "$dmg" "$dmg"
spctl -a -t open --context context:primary-signature -v "$dmg"
shasum -a 256 "$dmg"

# The update feed: Sparkle signs the DMG with the EdDSA key in your
# keychain (account ROOMY_SPARKLE_ACCOUNT) and writes dist/appcast.xml.
# Upload it to the GitHub release together with the DMG.
bin="$root/app/build/SourcePackages/artifacts/sparkle/Sparkle/bin"
feed="$(mktemp -d)"
cp "$dmg" "$feed/"
"$bin/generate_appcast" --account "${ROOMY_SPARKLE_ACCOUNT:-roomy}" \
  --download-url-prefix "https://github.com/jurek-zsl/Roomy/releases/download/v$version/" \
  --link "https://github.com/jurek-zsl/Roomy" "$feed"
cp "$feed/appcast.xml" "$dist/appcast.xml"
rm -rf "$feed"
echo "Upload: $dmg and $dist/appcast.xml"
