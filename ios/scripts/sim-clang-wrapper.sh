#!/bin/bash
# FPC 3.2.2 has no aarch64-iphonesim target, but its arm64 iOS code is valid simulator
# code: only the platform in the object's LC_BUILD_VERSION differs, and FPC leaves
# that to the assembler. Put this first on -FD as "clang" and objects come out for
# the simulator.
args=()
for a in "$@"; do
    case "$a" in
        arm64-apple-ios*) args+=("$a-simulator") ;;
        *) args+=("$a") ;;
    esac
done
exec /usr/bin/clang "${args[@]}"
