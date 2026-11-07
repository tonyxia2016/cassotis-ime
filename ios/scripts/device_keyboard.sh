#!/usr/bin/env bash
# Run a command inside a keyboard extension on the phone and fetch its report.
#   device_keyboard.sh <uikit|swiftui> <label> "<options>"
# The extension is restarted first, so marks and footprints are from a cold start.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
device="${CASSOTIS_DEVICE:-$(python3 -I "$root/scripts/find_device.py")}"
bundle=com.hustmobile.cassotis.poc
field="$1"; label="$2"; options="${3:-}"
timeout_s="${CASSOTIS_TIMEOUT:-600}"
want="$bundle.$([[ "$field" == swiftui ]] && echo swiftui || echo keyboard)"
run_host() {
    xcrun devicectl device process launch --device "$device" --terminate-existing \
        "$bundle" --field "$field" --keyboard "$want" --command "$1" >/dev/null 2>&1
}
list_reports() {
    xcrun devicectl device info files --device "$device" --domain-type appDataContainer \
        --domain-identifier "$bundle" --subdirectory Documents/reports 2>/dev/null \
        | awk '/^report-/{print $1}' | sort
}
pid_of() {
    xcrun devicectl device info processes --device "$device" 2>/dev/null \
        | awk -v n="/CassotisKeyboard${1}.appex/" 'index($0,n){print $1; exit}'
}
ext="$([[ "$field" == swiftui ]] && echo SwiftUI || echo "")"
if [[ "${CASSOTIS_KEEP_EXTENSION:-0}" != 1 ]]; then
    pid="$(pid_of "$ext")"
    if [[ -n "$pid" ]]; then
        xcrun devicectl device process terminate --device "$device" --pid "$pid" >/dev/null 2>&1 || true
        sleep 1
    fi
fi
before="$(list_reports)"
run_host "label=$label $options"
deadline=$((SECONDS + timeout_s))
new=""
while [[ $SECONDS -lt $deadline ]]; do
    sleep 5
    now="$(list_reports)"
    new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$now") | tail -1)"
    [[ -n "$new" ]] && break
done
[[ -n "$new" ]] || { echo "no report within ${timeout_s}s" >&2; exit 1; }
out="$root/results/$label.json"
xcrun devicectl device copy from --device "$device" --domain-type appDataContainer \
    --domain-identifier "$bundle" --source "Documents/reports/$new" --destination "$out" >/dev/null 2>&1
python3 -I "$root/scripts/show_report.py" "$out"
