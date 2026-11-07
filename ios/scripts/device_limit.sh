#!/usr/bin/env bash
# Find a keyboard extension's real memory limit: dirty memory until the system kills
# it, then read the last footprint it reported and the JetsamEvent the phone logged.
#   device_limit.sh <uikit|swiftui> <label> [step_mb]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
device="${CASSOTIS_DEVICE:-$(python3 -I "$root/scripts/find_device.py")}"
bundle=com.hustmobile.cassotis.poc
field="$1"; label="$2"; step="${3:-8}"
want="$bundle.$([[ "$field" == swiftui ]] && echo swiftui || echo keyboard)"
out="$root/results/$label"; rm -rf "$out"; mkdir -p "$out"
list() {
    xcrun devicectl device info files --device "$device" --domain-type appDataContainer \
        --domain-identifier "$bundle" --subdirectory Documents/reports 2>/dev/null \
        | awk '/^report-/{print $1}' | sort
}
pid_of() {
    xcrun devicectl device info processes --device "$device" 2>/dev/null \
        | awk -v n="/CassotisKeyboard$([[ "$field" == swiftui ]] && echo SwiftUI).appex/" 'index($0,n){print $1; exit}'
}
pid="$(pid_of)"
[[ -z "$pid" ]] || xcrun devicectl device process terminate --device "$device" --pid "$pid" >/dev/null 2>&1 || true
sleep 1
before="$(list)"
xcrun devicectl device process launch --device "$device" --terminate-existing "$bundle" \
    --field "$field" --keyboard "$want" --command "label=$label mode=limit step=$step" >/dev/null 2>&1
last_count=-1
for _ in $(seq 1 80); do
    sleep 3
    now="$(comm -13 <(printf '%s\n' "$before") <(list) | wc -l | tr -d ' ')"
    [[ "$now" == "$last_count" && "$now" != 0 ]] && break
    last_count="$now"
done
newest="$(comm -13 <(printf '%s\n' "$before") <(list) | tail -1)"
[[ -n "$newest" ]] || { echo "no reports" >&2; exit 1; }
xcrun devicectl device copy from --device "$device" --domain-type appDataContainer \
    --domain-identifier "$bundle" --source "Documents/reports/$newest" --destination "$out/last.json" >/dev/null 2>&1
echo "steps reported: $last_count"; cat "$out/last.json"; echo
log="$(xcrun devicectl device info files --device "$device" --domain-type systemCrashLogs 2>/dev/null \
    | awk '/^JetsamEvent-/{print $1}' | sort | tail -1)"
if [[ -n "$log" ]]; then
    xcrun devicectl device copy from --device "$device" --domain-type systemCrashLogs --source "$log" \
        --destination "$out/$log" >/dev/null 2>&1
    python3 -I - "$out/$log" <<'PY'
import json, sys
text = open(sys.argv[1]).read().split("\n", 1)
body = json.loads(text[1])
page = body.get("memoryStatus", {}).get("pageSize", 16384)
print("jetsam", json.loads(text[0]).get("timestamp"), "largest", body.get("largestProcess"))
for p in body.get("processes", []):
    if "Cassotis" in p.get("name", ""):
        print({k: p.get(k) for k in ("name", "reason", "rpages", "lifetimeMax", "killDelta") if k in p},
              "rpages_mb", round(p.get("rpages", 0) * page / 1048576, 1))
PY
fi
