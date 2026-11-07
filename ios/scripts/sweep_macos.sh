#!/usr/bin/env bash
# Replay on macOS across cache bounds. Usage: sweep_macos.sh <variant> <name>:<options...> ...
#   e.g. sweep_macos.sh macos-cmem "p100:cache_percent=100" "p25:cache_percent=25 sqlite_cache_kib=2048"
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
variant="$1"; shift
dict="$root/build/res/dict_sc.db"
out="$root/results/sweep"; mkdir -p "$out"
pids=()
for spec in "$@"; do
    name="${spec%%:*}"; opts="${spec#*:}"
    args=()
    for o in $opts; do args+=(--option "$o"); done
    "$root/build/$variant/replay" --dictionary "$dict" --resources "$root/build/res" --data "$root/build/data" \
        --corpus "$root/bench/corpus.tsv" --keys "${KEYS:-10000}" ${args[@]+"${args[@]}"} \
        --output "$out/$name.json" --digest "$out/$name.digest" --census "$out/$name.census" --label "$name" >/dev/null &
    pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || echo "failed $p" >&2; done
python3 -I - "$out" "$@" <<'PY'
import json,sys
out=sys.argv[1]
print(f"{'run':14}{'open':>6}{'end':>7}{'peak':>7}{'p50':>7}{'p95':>7}{'p99':>7}{'worst':>7}{'first':>7}  digest")
for spec in sys.argv[2:]:
    n=spec.split(':')[0]
    j=json.load(open(f'{out}/{n}.json'))
    print(f"{n:14}{j['after_open_mb']:6.1f}{j['end_mb']:7.1f}{j['peak_mb']:7.1f}{j['p50_ms']:7.1f}{j['p95_ms']:7.1f}{j['p99_ms']:7.1f}{j['worst_ms']:7.0f}{j['first_rate']:7.3f}  {j['digest']}")
PY
