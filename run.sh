#!/bin/bash
set -e

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
fi

PROJECT="/Users/nont/My-Project/PRC-PhotoBooth"
DERIVED="/Users/nont/Library/Developer/Xcode/DerivedData/PRC-PhotoBooth-ffpaetmksuppukabsklnqjccyygf"
DEVELOPER_ROOT="${DEVELOPER_DIR:-$(xcode-select -p)}"
SIMULATOR_APP="$DEVELOPER_ROOT/Applications/Simulator.app"
DEVICE_HUB_APP="$DEVELOPER_ROOT/../Applications/DeviceHub.app"
IPAD_SIM_NAME="${IPAD_SIM_NAME:-iPad Pro 13-inch (M5)}"
IPAD_SIM="${IPAD_SIM:-$(xcrun simctl list devices available \
  | awk -F '[()]' -v name="$IPAD_SIM_NAME" 'index($0, name) { gsub(/ /, "", $4); print $4; exit }')}"
if [[ -z "$IPAD_SIM" ]]; then
  echo "No available simulator named '$IPAD_SIM_NAME'."
  exit 1
fi
MAC_APP="$DERIVED/Build/Products/Debug/PRC-PhotoBooth-Mac.app"
IPAD_APP="$DERIVED/Build/Products/Debug-iphonesimulator/PRC-PhotoBooth-iPad.app"

cd "$PROJECT"

echo "==> Building..."
xcodebuild -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBooth-Mac \
  -configuration Debug build -quiet
xcodebuild -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBooth-iPad \
  -destination "platform=iOS Simulator,id=$IPAD_SIM" \
  -configuration Debug build -quiet
echo "    Done."

echo "==> Stopping existing instances..."
osascript -e 'if application id "com.nont.prcphoto.mac" is running then tell application id "com.nont.prcphoto.mac" to quit' >/dev/null 2>&1 || true
for i in $(seq 1 20); do
  pgrep -f "PRC-PhotoBooth-Mac.app/Contents/MacOS/PRC-PhotoBooth-Mac" >/dev/null 2>&1 || break
  sleep 0.25
done
pkill -9 -f "PRC-PhotoBooth-Mac.app/Contents/MacOS/PRC-PhotoBooth-Mac" 2>/dev/null || true
xcrun simctl terminate "$IPAD_SIM" com.nont.prcphoto.ipad 2>/dev/null || true

echo "==> Booting simulator..."
xcrun simctl boot "$IPAD_SIM" 2>/dev/null || true
if [[ -d "$SIMULATOR_APP" ]]; then
  open "$SIMULATOR_APP"
elif [[ -d "$DEVICE_HUB_APP" ]]; then
  open "$DEVICE_HUB_APP"
else
  echo "    Simulator UI unavailable; continuing with the booted simulator."
fi

echo "==> Launching Mac app..."
open "$MAC_APP"

echo "==> Installing and launching iPad app..."
xcrun simctl install "$IPAD_SIM" "$IPAD_APP"
xcrun simctl launch "$IPAD_SIM" com.nont.prcphoto.ipad

echo "==> Done. Both apps are running."
