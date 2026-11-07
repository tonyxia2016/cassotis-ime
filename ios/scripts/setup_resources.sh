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
# The shared character LM in its Core ML form (needs CASSOTIS_COREML_PYTHON, see
# macos/scripts/build_coreml_model.sh) with the files the hosts check against
# runtime_manifest.json. The engine opens <resources>/char_lm on a background thread.
"$mac/scripts/build_coreml_model.sh" --require
model="$mac/data/models/char_lm"
lm="$root/build/res/char_lm"
rm -rf "$lm" "$root/build/res/char_lm.mlmodelc"
mkdir -p "$lm"
cp "$model/char_lm_vocab.bin" "$model/pinyin_readings.json" "$model/runtime_manifest.json" "$lm/"
python3 -B "$mac/scripts/prepare_model_metadata.py" "$root/build/res"
cp -cR "$mac/build/coreml/char_lm.mlmodelc" "$lm/" 2>/dev/null || cp -R "$mac/build/coreml/char_lm.mlmodelc" "$lm/"
ls -la "$root/build/res" "$lm"
