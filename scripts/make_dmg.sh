#!/bin/bash
#
# make_dmg.sh — package a built .app into a drag-to-install .dmg
#
# Usage: scripts/make_dmg.sh <path-to-.app> <output-dmg-path> [volume-name]
#
# Produces a compressed (UDZO) disk image containing the app plus an
# /Applications symlink, so users can drag-and-drop to install. No external
# dependencies — uses only hdiutil, which ships with macOS.

set -euo pipefail

APP_PATH="${1:?usage: make_dmg.sh <app> <output.dmg> [volume-name]}"
DMG_PATH="${2:?usage: make_dmg.sh <app> <output.dmg> [volume-name]}"
VOL_NAME="${3:-Ntfy for Mac}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app bundle not found at: $APP_PATH" >&2
  exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "Staging $(basename "$APP_PATH") for DMG…"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$(dirname "$DMG_PATH")"
rm -f "$DMG_PATH"

echo "Creating DMG at $DMG_PATH (volume: $VOL_NAME)…"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG_PATH"

echo "Done: $DMG_PATH"
ls -lh "$DMG_PATH"
