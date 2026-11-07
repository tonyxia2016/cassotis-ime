#!/usr/bin/env bash
# Compares two nc_lm_* runtimes on the same cases: scoring with next characters
# and continuation (lmtest), large tries, and draft correction (lmcorrect).
#   ab.sh A_LIBRARY A_MODEL_DIR B_LIBRARY B_MODEL_DIR
# A is the reference (say libcassotis_ort.dylib with char_lm.onnx), B the one
# under test (libcassotis_coreml.dylib with char_lm.mlmodelc). A model folder
# holds the model, char_lm_vocab.bin and pinyin_readings.json.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
out="${CASSOTIS_LM_AB_OUT:-$(mktemp -d)}"
mkdir -p "$out"
xcrun clang++ -std=c++20 -O2 -Wall -Wextra "$here/lmtest.cpp" -o "$out/lmtest"
xcrun clang++ -std=c++20 -O2 -Wall -Wextra "$here/lmcorrect.cpp" -o "$out/lmcorrect"
readings="$2/pinyin_readings.json"
for set in char word big; do python3 -I "$here/cases.py" "$readings" "$set" >"$out/$set.tsv"; done
python3 -I "$here/correct_cases.py" "$readings" >"$out/correct.tsv"
for set in char word big; do
    "$out/lmtest" "$1" "$2" "$out/$set.tsv" >"$out/a_$set.jsonl"
    "$out/lmtest" "$3" "$4" "$out/$set.tsv" >"$out/b_$set.jsonl"
    echo "== $set"
    python3 -I "$here/compare.py" "$out/a_$set.jsonl" "$out/b_$set.jsonl"
done
"$out/lmcorrect" "$1" "$2" "$out/correct.tsv" >"$out/a_correct.jsonl"
"$out/lmcorrect" "$3" "$4" "$out/correct.tsv" >"$out/b_correct.jsonl"
echo "== correct"
python3 -I "$here/compare.py" --correct "$out/a_correct.jsonl" "$out/b_correct.jsonl"
echo "outputs in $out"
