#!/usr/bin/env bash
#
# capture_screenshots.sh — assisted App Store screenshot capture (no UI test)
#
# The "proper" automated route is `bundle exec fastlane screenshots`, which
# drives the EchoScreenshots UI test across the devices in fastlane/Snapfile.
# This script is the manual fallback: it boots a simulator with a clean
# status bar (9:41, full bars, 100% battery), then captures whatever is
# on screen each time you press Enter — you do the navigating, it does the
# pixel-perfect, correctly-named capture.
#
# Why this exists: Echo's UI is content-gated (Reader needs an EPUB, Stats
# needs due cards, etc.), so a few shots are easier to stage by hand than to
# automate. Captures land in fastlane/screenshots/<locale>/ ready for deliver.
#
# Usage:
#   Scripts/capture_screenshots.sh                       # iPhone 17 Pro Max, en-US
#   Scripts/capture_screenshots.sh "iPad Pro 13-inch (M5)"
#   Scripts/capture_screenshots.sh "iPhone 17 Pro Max" en-GB
#
# Requirements: Xcode command line tools (xcrun simctl). Build & install the
# app on the target simulator first (Cmd-R in Xcode, or `fastlane`), since this
# script only captures — it does not build.

set -euo pipefail

DEVICE_NAME="${1:-iPhone 17 Pro Max}"
LOCALE="${2:-en-US}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/fastlane/screenshots/${LOCALE}"
mkdir -p "${OUT_DIR}"

# Map a simulator device name to a short slug used in the filename.
slug_for_device() {
  case "$1" in
    *"iPad"*)  echo "iPad" ;;
    *"Mac"*)   echo "Mac" ;;
    *"Watch"*) echo "Watch" ;;
    *)         echo "iPhone" ;;
  esac
}
DEVICE_SLUG="$(slug_for_device "${DEVICE_NAME}")"

echo "→ Locating simulator: ${DEVICE_NAME}"
UDID="$(xcrun simctl list devices available | grep -F "${DEVICE_NAME} (" | head -1 | grep -oE '[0-9A-F-]{36}' || true)"
if [[ -z "${UDID}" ]]; then
  echo "✗ No available simulator named '${DEVICE_NAME}'." >&2
  echo "  Run 'xcrun simctl list devices available' and pass an exact name." >&2
  exit 1
fi

echo "→ Booting ${UDID} (no-op if already booted)…"
xcrun simctl boot "${UDID}" 2>/dev/null || true
open -a Simulator
xcrun simctl bootstatus "${UDID}" -b >/dev/null 2>&1 || true

echo "→ Applying clean marketing status bar (9:41, full bars, 100% battery)…"
xcrun simctl status_bar "${UDID}" override \
  --time "9:41" \
  --dataNetwork "wifi" --wifiMode "active" --wifiBars 3 \
  --cellularMode "active" --cellularBars 4 \
  --batteryState "charged" --batteryLevel 100

echo "→ Forcing dark appearance for App Store captures…"
xcrun simctl ui "${UDID}" appearance dark >/dev/null 2>&1 || {
  echo "  ⚠ Could not set dark appearance automatically; set it in Simulator before capture." >&2
}

cleanup() {
  echo ""
  echo "→ Clearing status bar override…"
  xcrun simctl status_bar "${UDID}" clear >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo ""
echo "Ready. Navigate the app in the simulator, then capture shots here."
echo "Files are written to: ${OUT_DIR}"
echo ""

index=1
while true; do
  printf "Shot %02d — name it (e.g. Player), or press Enter to finish: " "${index}"
  read -r name
  [[ -z "${name}" ]] && break

  filename="$(printf '%02d_%s_%s.png' "${index}" "${name}" "${DEVICE_SLUG}")"
  xcrun simctl io "${UDID}" screenshot "${OUT_DIR}/${filename}"
  echo "  ✓ saved ${filename}"
  index=$((index + 1))
done

echo ""
echo "Done. ${OUT_DIR} now holds your captures."
echo "Upload them with:  bundle exec fastlane upload_screenshots"
