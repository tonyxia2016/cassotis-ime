#!/usr/bin/env bash
# Run the in-process self test on the phone and print its summary.
#   device_selftest.sh <label> "<options>"
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
device="${CASSOTIS_DEVICE:-$(python3 -I "$root/scripts/find_device.py")}"
label="$1"; options="${2:-}"
console="$root/results/$label.console"
timeout "${CASSOTIS_TIMEOUT:-300}" xcrun devicectl device process launch --device "$device" --terminate-existing --console \
    com.hustmobile.cassotis.poc --selftest "label=$label $options" >"$console" 2>&1 &
launcher=$!
for _ in $(seq 1 280); do
    if grep -q '^}' "$console" 2>/dev/null; then break; fi
    sleep 1
done
pid="$(xcrun devicectl device info processes --device "$device" 2>/dev/null | awk '/CassotisPOC.app\/CassotisPOC/{print $1; exit}')"
[[ -n "$pid" ]] && xcrun devicectl device process terminate --device "$device" --pid "$pid" >/dev/null 2>&1 || true
wait "$launcher" 2>/dev/null || true
python3 -I - "$console" "$root/results/$label.json" <<'PY'
import json,sys
t=open(sys.argv[1]).read()
a=t.find('{'); b=t.rfind('\n}')
j=json.loads(t[a:b+2]); json.dump(j,open(sys.argv[2],'w'),indent=1)
print(f"{j['label']:24} open {j['before_open_mb']:.1f}->{j['after_open_mb']:.1f} ({j['open_seconds']:.2f}s) end {j['end_mb']:.1f} peak {j['peak_mb']:.1f} | p50 {j['p50_ms']:.1f} p95 {j['p95_ms']:.1f} p99 {j['p99_ms']:.1f} worst {j['worst_ms']:.0f} | keys {j['keys']} first {j['first_rate']:.3f} digest {j['digest']} err={j['error']}")
PY
