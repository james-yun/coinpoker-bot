#!/bin/sh
# Installs a pokerbot release: copies it to ~/.local/share/pokerbot and links pokerbot into ~/.local/bin.
#   ./install.sh               install, or upgrade in place (your config and bench spots are kept)
#   ./install.sh --uninstall   remove it (the config in ~/.config/pokerbot is left alone)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
DEST="${POKERBOT_HOME:-$HOME/.local/share/pokerbot}"
BIN="${POKERBOT_BIN:-$HOME/.local/bin}"

if [ "$1" = "--uninstall" ]; then
    rm -f "$BIN/pokerbot"
    rm -rf "$DEST"
    echo "removed $DEST and $BIN/pokerbot"
    exit 0
fi

[ "$(uname)" = "Darwin" ] || { echo "pokerbot runs on macOS only" >&2; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || { echo "pokerbot needs macOS 14 or later" >&2; exit 1; }
command -v python3 >/dev/null || { echo "pokerbot needs python3 (xcode-select --install)" >&2; exit 1; }

# keep what the user added to the benchmark across upgrades
keep=""
if [ -d "$DEST/bench" ] && [ "$HERE" != "$DEST" ]; then
    keep=$(mktemp -d)
    for f in spots.json spots results; do
        [ -e "$DEST/bench/$f" ] && cp -R "$DEST/bench/$f" "$keep/"
    done
fi

if [ "$HERE" != "$DEST" ]; then
    rm -rf "$DEST"
    mkdir -p "$(dirname "$DEST")"
    cp -R "$HERE" "$DEST"
fi
if [ -n "$keep" ]; then
    cp -R "$keep"/. "$DEST/bench/"
    rm -rf "$keep"
fi

# a browser download marks every file as quarantined, and Gatekeeper would refuse the unsigned engine
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

mkdir -p "$BIN"
ln -sf "$DEST/pokerbot" "$BIN/pokerbot"
echo "installed pokerbot $(cat "$DEST/VERSION" 2>/dev/null) to $DEST"
echo "linked $BIN/pokerbot"
case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo "note: $BIN is not on your PATH; add it in your shell profile, e.g.  export PATH=\"$BIN:\$PATH\"" ;;
esac
echo "next: pokerbot test, then pokerbot play (the terminal needs Screen Recording and Accessibility)"
