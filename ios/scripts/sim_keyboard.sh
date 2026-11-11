#!/usr/bin/env bash
# The same command channel as device_keyboard.sh, against build/sim.udid.
# CASSOTIS_PASTEBOARD=file: the host puts that file's text on the clipboard first
# (for the phrase import, {set:400}); simctl pbcopy does not reach this simulator.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
udid="$(cat "$root/build/sim.udid")"
field="$1"; options="${2:-}"; wait_s="${3:-120}"
bundle=com.hustmobile.cassotis.poc
xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
[[ "${CASSOTIS_KEEP_EXTENSION:-0}" == 1 ]] || pkill -f "CassotisKeyboard" || true
data="$(xcrun simctl get_app_container "$udid" "$bundle" data)"
rm -rf "$data/Documents/reports"
want="$bundle.$([[ "$field" == swiftui ]] && echo swiftui || echo keyboard)"
paste=()
if [[ -n "${CASSOTIS_PASTEBOARD:-}" ]]; then
    mkdir -p "$data/Documents" && cp "$CASSOTIS_PASTEBOARD" "$data/Documents/pasteboard.txt"
    paste=(--pasteboard pasteboard.txt)
fi
xcrun simctl launch "$udid" "$bundle" --field "$field" --keyboard "$want" --command "$options" \
    ${paste[@]+"${paste[@]}"} >/dev/null
data="$(xcrun simctl get_app_container "$udid" "$bundle" data)"
for _ in $(seq 1 "$wait_s"); do
    sleep 1
    if [[ -d "$data/Documents/reports" ]] && [[ -n "$(ls "$data/Documents/reports" 2>/dev/null)" ]]; then
        python3 -I "$root/scripts/show_report.py" "$data"/Documents/reports/*.json
        exit 0
    fi
done
echo "no report within ${wait_s}s" >&2
exit 1
