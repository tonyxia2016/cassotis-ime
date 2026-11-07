#!/usr/bin/env bash
# Link the macOS replay CLI against build/<variant>/libcassotis_core.a
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
variant="${1:-macos}"
out="$root/build/$variant"
xcrun clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=11.0 \
    -I"$root/../macos/src/embed" -I"$root/client" -I"$root/bench" \
    "$root/bench/replay_main.cpp" "$root/bench/replay.cpp" "$root/client/EngineClient.cpp" \
    -Wl,-force_load,"$out/libcassotis_core.a" -lsqlite3 -liconv \
    -framework CoreFoundation -Wl,-no_warn_duplicate_libraries \
    -o "$out/replay"
ls -la "$out/replay"
