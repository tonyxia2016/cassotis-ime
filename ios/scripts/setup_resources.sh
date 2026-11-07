#!/usr/bin/env bash
# Collect what the app bundles: the simplified dictionary built by macos/ (from the
# lexicon/ of this repository) and the schema. cp -c clones on APFS, so the 283 MB
# file costs no disk.
#   Build the dictionary first:  (cd ../macos && ./scripts/build_fpc.sh && python3 scripts/build_dictionaries.py)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
mac="${CASSOTIS_MAC_ROOT:-$root/../macos}"
dictionary="$mac/build/dictionaries/dict_sc.db"
[[ -f "$dictionary" ]] || { echo "missing $dictionary; build the macOS dictionaries first" >&2; exit 1; }
mkdir -p "$root/build/res" "$root/build/data"
cp -c "$dictionary" "$root/build/res/dict_sc.db" 2>/dev/null || cp "$dictionary" "$root/build/res/dict_sc.db"
cp "$mac/data/schema.sql" "$root/build/res/schema.sql"
ls -la "$root/build/res"
