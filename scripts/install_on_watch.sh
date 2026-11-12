#!/bin/sh
# Builds the app signed for a real Apple Watch, installs it and opens it. Needs App/Local.xcconfig (team + bundle id).
# Usage: scripts/install_on_watch.sh "Name of the watch as Xcode shows it"
# The connection to a watch drops whenever it sleeps, so every step is retried: keep the watch awake and unlocked.
set -u
NAME="${1:?usage: install_on_watch.sh \"<watch name>\"}"
cd "$(dirname "$0")/../App" || exit 2
[ -f Local.xcconfig ] || { echo "App/Local.xcconfig is missing: copy Local.xcconfig.example and fill it in"; exit 2; }
command -v xcodegen >/dev/null || { echo "xcodegen is missing: brew install xcodegen"; exit 2; }
xcodegen generate >/dev/null || exit 2
BUNDLE=$(grep -E '^HERMES_BUNDLE_ID' Local.xcconfig | sed 's/.*= *//')
i=0
while [ $i -lt 20 ]; do
  i=$((i+1))
  # xcodebuild only matches a real watch by id, not by name
  DEST=$(xcodebuild -project HermesWatch.xcodeproj -scheme HermesWatch -showdestinations 2>/dev/null | grep "platform:watchOS, arch" | grep "name:$NAME" | sed -E 's/.*id:([^,]+),.*/\1/' | head -1)
  if [ -n "$DEST" ] && xcodebuild -project HermesWatch.xcodeproj -scheme HermesWatch -configuration Debug -destination "id=$DEST" -derivedDataPath build/device -allowProvisioningUpdates -allowProvisioningDeviceRegistration build > build_device.log 2>&1; then echo "build ok"; break; fi
  [ -n "$DEST" ] && ! grep -q "Unable to find a device" build_device.log && { echo "build failed: see App/build_device.log"; exit 1; }
  echo "watch not reachable (try $i), waiting"; DEST=""; sleep 15
done
[ -n "$DEST" ] || { echo "the watch never became reachable"; exit 3; }
APP=$(find build/device/Build/Products -maxdepth 2 -name "HermesWatch.app" -path "*watchos*" | head -1)
i=0
while [ $i -lt 24 ]; do
  i=$((i+1))
  if xcrun devicectl device install app --device "$NAME" "$APP" > install_device.log 2>&1; then
    echo "installed"; xcrun devicectl device process launch --terminate-existing --device "$NAME" "$BUNDLE" >/dev/null 2>&1 && echo "opened"; exit 0
  fi
  echo "install failed (try $i), waiting"; sleep 15
done
echo "install never went through: see App/install_device.log"; exit 3
