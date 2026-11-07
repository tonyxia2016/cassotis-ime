#!/usr/bin/env bash
# Build the POC app and keyboard (Release, device), then sign them with the team's
# wildcard development profile. Nothing here touches the developer account.
#   CASSOTIS_PROFILE   path of a .mobileprovision (default: the wildcard one)
#   CASSOTIS_IDENTITY  codesigning identity hash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
config="${CASSOTIS_CONFIG:-Release}"
dd="$root/build/dd"
xcodebuild -project "$root/app/CassotisPOC.xcodeproj" -scheme CassotisPOC \
    -configuration "$config" -sdk iphoneos -derivedDataPath "$dd" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build >"$root/build/xcodebuild.log" 2>&1 || {
    grep -E 'error:|Undefined|ld:|fatal' "$root/build/xcodebuild.log" | cut -c1-260 | head -30 >&2
    tail -3 "$root/build/xcodebuild.log" | cut -c1-200 >&2
    exit 1
}
app="$dd/Build/Products/$config-iphoneos/CassotisPOC.app"
appex="$app/PlugIns/CassotisKeyboard.appex"

profile="${CASSOTIS_PROFILE:-}"
if [[ -z "$profile" ]]; then
    for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.mobileprovision; do
        name="$(security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw -o - - 2>/dev/null || true)"
        if [[ "$name" == "iOS Team Provisioning Profile: *" ]]; then profile="$f"; break; fi
    done
fi
[[ -n "$profile" ]] || { echo "no provisioning profile found" >&2; exit 1; }
identity="${CASSOTIS_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')}"
team="$(security cms -D -i "$profile" 2>/dev/null | plutil -extract TeamIdentifier.0 raw -o - -)"

sign() {  # bundle bundle-id
    local entitlements="$root/build/$2.entitlements"
    cat >"$entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>application-identifier</key><string>$team.$2</string>
<key>com.apple.developer.team-identifier</key><string>$team</string>
<key>get-task-allow</key><true/>
<key>keychain-access-groups</key><array><string>$team.*</string></array>
${CASSOTIS_EXTRA_ENTITLEMENTS:-}
</dict></plist>
PLIST
    cp "$profile" "$1/embedded.mobileprovision"
    codesign --force --sign "$identity" --entitlements "$entitlements" --generate-entitlement-der "$1"
}
sign "$appex" com.hustmobile.cassotis.poc.keyboard
sign "$app/PlugIns/CassotisKeyboardSwiftUI.appex" com.hustmobile.cassotis.poc.swiftui
sign "$app" com.hustmobile.cassotis.poc
codesign --verify --deep --strict "$app"
du -sh "$app" "$appex/CassotisKeyboard" "$app/PlugIns/CassotisKeyboardSwiftUI.appex/CassotisKeyboardSwiftUI"
echo "$app"
