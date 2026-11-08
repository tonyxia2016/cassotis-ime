#!/usr/bin/env bash
# Cross-build the Free Pascal 3.2.2 runtime and the handful of package units
# the engine uses for aarch64-ios, with the stock Homebrew ppca64 as compiler.
# No compiler rebuild is needed: ppca64 3.2.2 already accepts -Tios -Paarch64.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
src="$root/toolchain/src/fpc-3.2.2"
# CASSOTIS_SIMULATOR=1 builds the same units for the iOS Simulator into ios-sim-units.
simulator="${CASSOTIS_SIMULATOR:-0}"
if [[ "$simulator" == 1 ]]; then out="$root/toolchain/ios-sim-units"; else out="$root/toolchain/ios-units"; fi
log="$root/toolchain/logs"
ppc="${CASSOTIS_PPC:-/opt/homebrew/lib/fpc/3.2.2/ppca64}"
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
min_ios="${CASSOTIS_MIN_IOS:-18.0}"
rm -rf "$out"   # a unit that looks up to date could carry the other platform's tag
mkdir -p "$out/rtl" "$out/pkg" "$log"

if [[ ! -d "$src" ]]; then
    mkdir -p "$root/toolchain/src"
    git clone --quiet --depth 1 --branch release_3_2_2 \
        https://gitlab.com/freepascal.org/fpc/source.git "$src"
fi
[[ "$("$ppc" -iV)" == 3.2.2 ]] || { echo "need ppca64 3.2.2" >&2; exit 1; }

common=(-n -Tios -Paarch64 "-XR$sdk" "-WP$min_ios" -O2 -g-)
extra=""
if [[ "$simulator" == 1 ]]; then
    sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
    mkdir -p "$root/toolchain/sim-bin"
    cp "$root/scripts/sim-clang-wrapper.sh" "$root/toolchain/sim-bin/clang"
    common=(-n -Tios -Paarch64 "-XR$sdk" "-WP$min_ios" -O2 -g- "-FD$root/toolchain/sim-bin")
    extra="-FD$root/toolchain/sim-bin"
fi

echo "[rtl] make"
make -C "$src/rtl" clean CPU_TARGET=aarch64 OS_TARGET=ios FPC="$ppc" >/dev/null 2>&1 || true
# Serial on purpose: the RTL Makefile does not declare all its .ppu edges.
make -C "$src/rtl" all FPC="$ppc" CPU_TARGET=aarch64 OS_TARGET=ios \
    CROSSOPT="-XR$sdk -WP$min_ios $extra" OPT="-O2 -g-" >"$log/rtl.log" 2>&1
cp "$src"/rtl/units/aarch64-ios/* "$out/rtl/"

compile() {
    local name="$1"; shift
    printf '[pkg] %s\n' "$name"
    "$ppc" "${common[@]}" "-Fu$out/rtl" "-Fu$out/pkg" "-FU$out/pkg" "$@" \
        >>"$log/packages.log" 2>&1 || { tail -40 "$log/packages.log" >&2; exit 1; }
}
: >"$log/packages.log"
p="$src/packages"
compile dateutils "-Fi$p/rtl-objpas/src/inc" "$p/rtl-objpas/src/inc/dateutils.pp"
compile strutils  "-Fi$p/rtl-objpas/src/inc" "$p/rtl-objpas/src/inc/strutils.pp"
compile varutils  "-Fi$p/rtl-objpas/src/inc" "-Fi$p/rtl-objpas/src/unix" "$p/rtl-objpas/src/common/varutils.pp"
compile variants  "-Fi$p/rtl-objpas/src/inc" "$p/rtl-objpas/src/inc/variants.pp"
compile contnrs   "$p/fcl-base/src/contnrs.pp"
compile syncobjs  "$p/fcl-base/src/syncobjs.pp"
g="$p/rtl-generics/src"
compile generics  "-Fi$g/inc" "-Fu$g" "$g/generics.collections.pas"
j="$p/fcl-json/src"
compile fpjson    "-Fu$j" "$j/fpjson.pp"
compile jsonscanner "-Fu$j" "$j/jsonscanner.pp"
compile jsonreader  "-Fu$j" "$j/jsonreader.pp"
compile jsonparser  "-Fu$j" "$j/jsonparser.pp"
echo "ok: units in $out"
