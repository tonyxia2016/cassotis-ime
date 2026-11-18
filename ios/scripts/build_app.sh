#!/usr/bin/env bash
# Build the app and its keyboards (Release, device), then sign them. The keyboard people
# use syncs through iCloud, which needs its own development profile (explicit App ID
# with the container and App Group, from macos/scripts/provision_icloud.py). The host
# uses its own iCloud profile; the test keyboard uses the wildcard profile.
#   CASSOTIS_PROFILE   path of a .mobileprovision (default: the wildcard one)
#   CASSOTIS_IDENTITY  codesigning identity hash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
config="${CASSOTIS_CONFIG:-Release}"
host="${CASSOTIS_HOST_ID:-com.hustmobile.cassotis}"
keyboard="${CASSOTIS_KEYBOARD_ID:-com.hustmobile.cassotis.keyboard}"
test_keyboard="${CASSOTIS_TEST_ID:-com.hustmobile.cassotis.testkeyboard}"
dd="${CASSOTIS_DERIVED_DATA:-$root/build/dd}"
xcodebuild -project "$root/app/CassotisPOC.xcodeproj" -scheme CassotisPOC \
    -configuration "$config" -sdk iphoneos -derivedDataPath "$dd" \
    CASSOTIS_HOST_ID="$host" CASSOTIS_KEYBOARD_ID="$keyboard" CASSOTIS_TEST_ID="$test_keyboard" \
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

sign() {  # bundle bundle-id [profile [extra entitlements]]
    local entitlements="$root/build/$2.entitlements"
    cat >"$entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>application-identifier</key><string>$team.$2</string>
<key>com.apple.developer.team-identifier</key><string>$team</string>
<key>get-task-allow</key><true/>
<key>keychain-access-groups</key><array><string>$team.*</string></array>
${4:-}
${CASSOTIS_EXTRA_ENTITLEMENTS:-}
</dict></plist>
PLIST
    cp "${3:-$profile}" "$1/embedded.mobileprovision"
    codesign --force --sign "$identity" --entitlements "$entitlements" --generate-entitlement-der "$1"
}
icloud='<key>com.apple.developer.icloud-container-identifiers</key><array><string>iCloud.com.hustmobile.cassotis</string></array>
<key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
<key>com.apple.developer.icloud-container-environment</key><string>Development</string>'
keyboard_profile="$(python3 -B "$root/../macos/scripts/signing_profile.py" ios "$keyboard" || true)"
host_profile="$(python3 -B "$root/../macos/scripts/signing_profile.py" ios "$host" || true)"
group=group.com.hustmobile.cassotis
has_group() {
    [[ -f "$1" ]] && security cms -D -i "$1" | python3 -c 'import plistlib,sys; sys.exit(sys.argv[1] not in plistlib.loads(sys.stdin.buffer.read())["Entitlements"].get("com.apple.security.application-groups", []))' "$group"
}
# Only enable the background queue if both signed processes can reach it.
if has_group "${keyboard_profile%%$'\t'*}" && has_group "${host_profile%%$'\t'*}"; then
    icloud+="<key>com.apple.security.application-groups</key><array><string>$group</string></array>"
else
    echo "App Group unavailable: iCloud sync runs when the keyboard is active" >&2
fi
sign_cloud() {
    local bundle="$1" identifier="$2" match="$3"
    if [[ -n "$match" ]]; then
        /usr/libexec/PlistBuddy -c "Delete :CassotisCloudKitUnavailable" "$bundle/Info.plist" >/dev/null 2>&1 || true
        sign "$bundle" "$identifier" "${match%%$'\t'*}" "$icloud"
    else
        /usr/libexec/PlistBuddy -c 'Add :CassotisCloudKitUnavailable bool true' "$bundle/Info.plist" 2>/dev/null ||
            /usr/libexec/PlistBuddy -c 'Set :CassotisCloudKitUnavailable true' "$bundle/Info.plist"
        echo "No iCloud development profile for $identifier" >&2
        sign "$bundle" "$identifier"
    fi
}
sign_cloud "$app/PlugIns/CassotisKeyboardSwiftUI.appex" "$keyboard" "$keyboard_profile"
sign "$appex" "$test_keyboard"
sign_cloud "$app" "$host" "$host_profile"
codesign --verify --deep --strict "$app"
du -sh "$app" "$appex/CassotisKeyboard" "$app/PlugIns/CassotisKeyboardSwiftUI.appex/CassotisKeyboardSwiftUI"
echo "$app"
