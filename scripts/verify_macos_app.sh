#!/bin/bash
set -euo pipefail

app="${1:?Usage: verify_macos_app.sh APP_BUNDLE}"
plist="$app/Contents/Info.plist"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
binary="$app/Contents/MacOS/$executable"

echo "Architectures: $(xcrun lipo -archs "$binary")"
xcrun lipo -verify_arch arm64 x86_64 "$binary"

for arch in arm64 x86_64; do
  minimum="$(xcrun vtool -arch "$arch" -show-build "$binary" | awk '$1 == "minos" { print $2 }')"
  case "$minimum" in
    13.0|13.0.0) echo "$arch minimum macOS: $minimum" ;;
    *) echo "Expected macOS 13.0 for $arch, got '${minimum:-unknown}'" >&2; exit 1 ;;
  esac
done
