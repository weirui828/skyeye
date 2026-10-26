#!/bin/bash
# Produces a drag-to-Applications disk image and app ZIP. No user data is included.
set -euo pipefail
cd "$(dirname "$0")/.."

export UNIVERSAL="${UNIVERSAL:-1}"
export CONFIG=release
if [[ -n "${NOTARY_PROFILE:-}" && "${SIGNING_IDENTITY:--}" == "-" ]]; then
    echo "Notarization requires SIGNING_IDENTITY to be a Developer ID Application identity." >&2
    exit 1
fi

./scripts/build.sh
APP="build/SkyEye.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCH="$(uname -m)"
if [[ "$UNIVERSAL" == "1" ]]; then
    ARCH="universal"
    for executable in SkyEye sky skyeye-mcp skyeye-logwriter; do
        ARCHS="$(/usr/bin/lipo -archs "$APP/Contents/MacOS/$executable")"
        if [[ " $ARCHS " != *" arm64 "* || " $ARCHS " != *" x86_64 "* ]]; then
            echo "$executable is missing a required architecture: $ARCHS" >&2
            exit 1
        fi
    done
fi
NAME="SkyEye-$VERSION-$ARCH"
ZIP="build/$NAME.zip"
DMG="build/$NAME.dmg"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
fi
# ZIP preserves executable permissions and the complete application bundle.
ditto -c -k --keepParent "$APP" "$ZIP"

STAGING="$(mktemp -d "$PWD/build/dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/SkyEye.app"
ln -s /Applications "$STAGING/Applications"
cp LICENSE "$STAGING/LICENSE.txt"
cat > "$STAGING/Install.txt" <<'TEXT'
Drag SkyEye.app into Applications, then open it from Applications.
SkyEye lives in the menu bar. The telescope icon opens your services.
For updates, quit SkyEye before replacing the app. Canceling the quit keeps it running.
Service definitions and logs are stored separately and survive app updates.
Command-line tools are optional; AI agent setup is available in Settings.
TEXT
hdiutil create -volname "SkyEye" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
if [[ "${SIGNING_IDENTITY:--}" != "-" ]]; then
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi
(cd build && shasum -a 256 "$NAME.zip" "$NAME.dmg" > "$NAME-SHA256SUMS.txt")
echo "Packaged $DMG and $ZIP"
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    echo "Developer preview only: this package is not notarized for public distribution."
fi
