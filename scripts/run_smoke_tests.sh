#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${TMPDIR:-/tmp}/ntfymac-smoke-tests"
TARGET="$(uname -m)-apple-macos13.0"
trap 'rm -f "$OUTPUT"' EXIT

cd "$ROOT"
xcrun swiftc -parse-as-library -target "$TARGET" \
  NtfyMac/Models/NtfyMessage.swift \
  NtfyMac/Models/Subscription.swift \
  NtfyMac/Models/ConnectionState.swift \
  NtfyMac/Models/AppSettings.swift \
  NtfyMac/Services/EmojiMap.swift \
  NtfyMac/Services/LaunchAtLogin.swift \
  NtfyMac/Services/ProxyConfig.swift \
  NtfyMac/Services/HostsMappedHTTPClient.swift \
  NtfyMac/Services/NtfyConnection.swift \
  NtfyMac/Services/ConfigurationBackup.swift \
  NtfyMac/Views/DesignSystem.swift \
  Tests/SmokeHarness.swift \
  -o "$OUTPUT"

"$OUTPUT"
