#!/usr/bin/env bash
# Builds the Core ML form of the shared character LM: build/coreml/char_lm.mlmodelc,
# converted from data/models/char_lm/char_lm.onnx by char_lm_coreml.py and
# compiled by Xcode's coremlcompiler. The macOS bundle and the iOS keyboard
# take it from there; the hosts open it with Core ML (nc_lm_runtime.pas).
#
# The converter needs numpy, onnx and coremltools (tested: coremltools 9.0,
# onnx 1.23, numpy 2.5). CASSOTIS_COREML_PYTHON names an interpreter that has
# them (a virtual environment, say); default python3. Without them the script
# says so and exits 0, and the bundle keeps ONNX Runtime alone; --require makes
# that an error.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
python="${CASSOTIS_COREML_PYTHON:-python3}"
require=0
for arg in "$@"; do
    case "$arg" in
        --require) require=1;;
        *) echo "Unknown argument: $arg" >&2; exit 2;;
    esac
done
model="$root/data/models/char_lm"
out="$root/build/coreml"
python3 -B "$root/scripts/char_lm_model_parts.py" "$model"
expected="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["files"]["char_lm.onnx"])' \
    "$model/runtime_manifest.json")"
recorded() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["userDefinedMetadata"].get("cassotis_source_sha256", ""))' \
        "$out/char_lm.mlmodelc/metadata.json" 2>/dev/null || true
}
if [[ -f "$out/char_lm.mlmodelc/metadata.json" ]] && [[ "$(recorded)" == "$expected" ]]; then
    printf '[Core ML] char_lm.mlmodelc is current\n'
    exit 0
fi
if ! "$python" -c 'import coremltools, onnx, numpy' >/dev/null 2>&1; then
    printf '[Core ML] skipped: %s lacks coremltools/onnx/numpy (set CASSOTIS_COREML_PYTHON)\n' "$python" >&2
    exit "$require"
fi
printf '[Core ML] converting char_lm.onnx\n'
mkdir -p "$out"
"$python" -B "$root/scripts/char_lm_coreml.py" --onnx "$model/char_lm.onnx" \
    --out "$out/char_lm.mlpackage" --compile "$out"
[[ "$(recorded)" == "$expected" ]] || { echo 'Core ML model does not record the manifest hash' >&2; exit 1; }
