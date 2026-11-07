#!/usr/bin/env bash
# Build for the iOS Simulator and install on the device in build/sim.udid.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
udid="$(cat "$root/build/sim.udid")"
xcodebuild -project "$root/app/CassotisPOC.xcodeproj" -scheme CassotisPOC -configuration Release \
    -sdk iphonesimulator -arch arm64 -derivedDataPath "$root/build/dd-sim" CODE_SIGNING_ALLOWED=NO build \
    >"$root/build/xcodebuild-sim.log" 2>&1 || { grep -E ' error:|^ld:' "$root/build/xcodebuild-sim.log" | cut -c1-240 | head -20 >&2; exit 1; }
xcrun simctl install "$udid" "$root/build/dd-sim/Build/Products/Release-iphonesimulator/CassotisPOC.app"
