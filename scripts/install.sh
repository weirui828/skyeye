#!/bin/bash
# Builds SkyEye, installs it to ~/Applications and links `sky` and `skyeye-mcp` into ~/.local/bin.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${DEST:-$HOME/Applications}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

./scripts/build.sh

if pgrep -x SkyEye >/dev/null; then
    echo "Quitting the running SkyEye (this stops its services unless \"Keep services running\" is on)…"
    if ! osascript -e 'quit app id "dev.skyeye.SkyEye"'; then
        echo "Installation canceled: SkyEye did not quit. The installed app has not been changed." >&2
        exit 1
    fi
    for ((attempt = 0; attempt < 50; attempt++)); do
        if ! pgrep -x SkyEye >/dev/null; then break; fi
        sleep 0.2
    done
    if pgrep -x SkyEye >/dev/null; then
        echo "SkyEye is still running. Installation stopped without replacing it." >&2
        exit 1
    fi
fi

mkdir -p "$DEST" "$BIN_DIR"
rm -rf "$DEST/SkyEye.app"
cp -R build/SkyEye.app "$DEST/"
ln -sf "$DEST/SkyEye.app/Contents/MacOS/sky" "$BIN_DIR/sky"
ln -sf "$DEST/SkyEye.app/Contents/MacOS/skyeye-mcp" "$BIN_DIR/skyeye-mcp"
open "$DEST/SkyEye.app"

echo "Installed $DEST/SkyEye.app"
echo "Linked $BIN_DIR/sky and $BIN_DIR/skyeye-mcp"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "Add $BIN_DIR to your PATH, e.g.: echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc" ;;
esac
