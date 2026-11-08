#!/usr/bin/env bash
# Build the engine into a static archive: build/<platform>/libcassotis_core.a
#   build_engine.sh ios     aarch64-ios, needs scripts/build_toolchain.sh first
#   build_engine.sh ios-sim the iOS Simulator; needs CASSOTIS_SIMULATOR=1 build_toolchain.sh
#   build_engine.sh macos   aarch64-darwin, same sources, for fast measurements
# Extra FPC options come from CASSOTIS_FPC_DEFINES (e.g. "-dCASSOTIS_CMEM").
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
platform="${1:?usage: build_engine.sh ios|macos}"
variant="${CASSOTIS_VARIANT:-$platform}"
ppc="${CASSOTIS_PPC:-/opt/homebrew/lib/fpc/3.2.2/ppca64}"
out="$root/build/$variant"
units="$out/units"
mkdir -p "$units"

# The engine is the one macOS builds: ../macos/src. Same floating point and string
# settings as macos/scripts/build_fpc.sh.
args=(-n -Paarch64 -Mdelphiunicode -FcUTF8 -CF64 -vm2091 -vm4110 -O2 -g- -Si -Sh
      -vew -Cn -dCASSOTIS_EMBEDDED "-FE$out" "-FU$units")
case "$platform" in
    ios)
        sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
        args+=(-Tios "-XR$sdk" "-WP${CASSOTIS_MIN_IOS:-18.0}"
               "-Fu$root/toolchain/ios-units/rtl" "-Fu$root/toolchain/ios-units/pkg")
        ;;
    ios-sim)
        sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
        args+=(-Tios "-XR$sdk" "-WP${CASSOTIS_MIN_IOS:-18.0}" "-FD$root/toolchain/sim-bin"
               "-Fu$root/toolchain/ios-sim-units/rtl" "-Fu$root/toolchain/ios-sim-units/pkg")
        ;;
    macos)
        sdk="$(xcrun --sdk macosx --show-sdk-path)"
        base=/opt/homebrew/lib/fpc/3.2.2/units/aarch64-darwin
        args+=(-Tdarwin "-XR$sdk" -WM11.0)
        for d in rtl rtl-objpas rtl-generics rtl-extra fcl-base fcl-json; do args+=("-Fu$base/$d"); done
        ;;
    *) echo "unknown platform $platform" >&2; exit 2 ;;
esac
engine="$(cd "$root/../macos/src" && pwd -P)"
for d in common engine dictionary ipc service host embed; do args+=("-Fu$engine/$d"); done
# shellcheck disable=SC2206
args+=(${CASSOTIS_FPC_DEFINES:-})

stamp="$(printf '%s\n' "$ppc" "${args[@]}" | shasum -a 256 | cut -d ' ' -f 1)"
if [[ ! -f "$units/.options" ]] || [[ "$(cat "$units/.options")" != "$stamp" ]]; then
    rm -rf "$units"; mkdir -p "$units"; printf '%s\n' "$stamp" >"$units/.options"
fi

rm -f "$out"/link*.res "$out"/linkfiles*.res "$out"/linksyms*.fpc
printf '[fpc %s] cassotis_core\n' "$variant"
if ! "$ppc" "${args[@]}" "$engine/embed/cassotis_core.lpr" >"$out/fpc.log" 2>&1; then
    grep -vE 'Wincompatible-sysroot' "$out/fpc.log" | tail -30 >&2
    exit 1
fi

# The Core ML runtime of the character LM (nc_lm_*, see nc_lm_runtime.pas): the
# engine links it where the desktop build loads libcassotis_ort.dylib. With
# -fcxx-modules the object asks the linker for CoreML and Foundation itself;
# the host links libc++. APIs newer than the deployment target are guarded.
case "$platform" in
    ios) target="arm64-apple-ios${CASSOTIS_MIN_IOS:-18.0}" ;;
    ios-sim) target="arm64-apple-ios${CASSOTIS_MIN_IOS:-18.0}-simulator" ;;
    macos) target="arm64-apple-macos11.0" ;;
esac
printf '[clang %s] nc_char_lm_coreml\n' "$variant"
xcrun clang++ -target "$target" -isysroot "$sdk" -std=c++20 -fobjc-arc -fmodules -fcxx-modules \
    -O2 -g -Wall -Wextra -Werror -ffp-contract=off -fvisibility=hidden \
    -c "$engine/host/native/nc_char_lm_coreml.mm" -o "$out/nc_char_lm_coreml.o"

# -Cn leaves the linker's script behind: its object list is the archive's content.
python3 -B "$root/scripts/archive_from_linkres.py" "$out" "$out/libcassotis_core.a" "$out/nc_char_lm_coreml.o"
ls -la "$out/libcassotis_core.a"
