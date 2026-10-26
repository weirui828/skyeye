#!/bin/bash
# Builds build/SkyEye.app (menu bar app + sky CLI + skyeye-mcp inside Contents/MacOS).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
BUILD_ARGS=(-c "$CONFIG" --disable-sandbox)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
# --disable-sandbox: SwiftPM's own manifest sandbox cannot nest inside a
# workspace sandbox (the DSH/CI build sandbox denies sandbox-exec).
swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

APP="build/SkyEye.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SkyEyeApp" "$APP/Contents/MacOS/SkyEye"
cp "$BIN/sky" "$BIN/skyeye-mcp" "$BIN/skyeye-logwriter" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Telescope.pdf "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE"

if [[ "$CONFIG" == "release" ]]; then
    for executable in SkyEye sky skyeye-mcp skyeye-logwriter; do
        /usr/bin/strip -S "$APP/Contents/MacOS/$executable"
    done
fi

# Local builds use ad-hoc signing. Release maintainers can supply a Developer ID identity.
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
SIGN_ARGS=(--timestamp=none)
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    SIGN_ARGS=(--options runtime --timestamp)
fi
for executable in sky skyeye-mcp skyeye-logwriter; do
    codesign --force --sign "$SIGNING_IDENTITY" "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/$executable"
done
codesign --force --sign "$SIGNING_IDENTITY" "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP"
