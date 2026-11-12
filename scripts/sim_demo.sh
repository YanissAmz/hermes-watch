#!/bin/sh
# Builds the app for the watch simulator, runs one real turn through a local bridge and saves screenshots.
# Usage: HERMES_TOKEN=<token> scripts/sim_demo.sh ["Simulator name"] ["prompt"]   (the bridge must run on 127.0.0.1:9120)
set -u
cd "$(dirname "$0")/.." || exit 2
D="${1:-Apple Watch Series 12 (46mm)}"; PROMPT="${2:-Explain the KV cache in two sentences, in English.}"
: "${HERMES_TOKEN:?set HERMES_TOKEN to the bridge token}"
command -v xcodegen >/dev/null || { echo "xcodegen is missing: brew install xcodegen"; exit 2; }
(cd App && xcodegen generate >/dev/null && xcodebuild -project HermesWatch.xcodeproj -scheme HermesWatch -configuration Debug \
  -destination "platform=watchOS Simulator,name=$D" -derivedDataPath build CODE_SIGNING_ALLOWED=NO \
  "HERMES_BRIDGE_URL=http:/\$()/127.0.0.1:9120" "HERMES_BRIDGE_TOKEN=$HERMES_TOKEN" build 2>&1 | grep -E "error:|BUILD") || exit 1
APP=App/build/Build/Products/Debug-watchsimulator/HermesWatch.app
BUNDLE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")
xcrun simctl boot "$D" 2>/dev/null; xcrun simctl bootstatus "$D" -b >/dev/null 2>&1
xcrun simctl terminate "$D" "$BUNDLE" 2>/dev/null; xcrun simctl install "$D" "$APP"
OUT=docs/screenshots; mkdir -p $OUT
SIMCTL_CHILD_HERMES_DEMO_PROMPT="$PROMPT" xcrun simctl launch "$D" "$BUNDLE" -AppleLanguages "(en)" -AppleLocale en_US >/dev/null
sleep 11; xcrun simctl io "$D" screenshot $OUT/chat_sent.png 2>/dev/null
sleep 35; xcrun simctl io "$D" screenshot $OUT/chat_reply.png 2>/dev/null
xcrun simctl terminate "$D" "$BUNDLE" 2>/dev/null
echo "screenshots in $OUT (the demo conversation stays in Hermes: delete it there if you do not want it)"
