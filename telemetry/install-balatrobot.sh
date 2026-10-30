#!/usr/bin/env bash
# Installs what the e2e test needs: Lovely v0.10.0, Steamodded 1.0.0-beta-1814a and BalatroBot v1.5.2
# (macOS, Apple Silicon). The replaced Lovely and Steamodded are moved to
# ~/Library/Application Support/Balatro/mods-backup-<date>/ first; to roll back, copy them back.
set -euo pipefail
APP="$HOME/Library/Application Support/Balatro"
GAME="$HOME/Library/Application Support/Steam/steamapps/common/Balatro"
BACKUP="$APP/mods-backup-$(date +%Y-%m-%d)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pgrep -f "Balatro.app/Contents/MacOS/love" >/dev/null && { echo "Quit Balatro first"; exit 1; }

cd "$TMP"
curl -sfL -o lovely.tgz https://github.com/ethangreen-dev/lovely-injector/releases/download/v0.10.0/lovely-aarch64-apple-darwin.tar.gz
curl -sfL -o smods.zip https://github.com/Steamodded/smods/archive/refs/tags/1.0.0-beta-1814a.zip
curl -sfL -o bb.zip https://github.com/coder/balatrobot/archive/refs/tags/v1.5.2.zip
mkdir lovely && tar -xzf lovely.tgz -C lovely
unzip -q smods.zip && unzip -q bb.zip

mkdir -p "$BACKUP"
[ -d "$APP/Mods/smods" ] && mv "$APP/Mods/smods" "$BACKUP/smods"
cp "$GAME/liblovely.dylib" "$GAME/run_lovely_macos.sh" "$BACKUP/" 2>/dev/null || true

cp lovely/liblovely.dylib lovely/run_lovely_macos.sh "$GAME/"
cp -R smods-1.0.0-beta-1814a "$APP/Mods/smods"
rm -rf "$APP/Mods/balatrobot" && mkdir -p "$APP/Mods/balatrobot/src"
cp balatrobot-1.5.2/balatrobot.json balatrobot-1.5.2/balatrobot.lua "$APP/Mods/balatrobot/"
cp -R balatrobot-1.5.2/src/lua "$APP/Mods/balatrobot/src/lua"

echo "Installed. Backup of the previous Lovely/Steamodded: $BACKUP"
cat "$APP/Mods/smods/version.lua"; echo
