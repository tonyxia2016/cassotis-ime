#!/usr/bin/env bash
# Bring the fcitx5-ios panel into one Swift module for the SwiftUI keyboard.
# Output goes to build/fcitxui (never committed; the sources stay upstream's, GPL-3.0).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
src="$root/toolchain/src"
[[ -d "$src/fcitx5-ios" ]] || git clone --quiet --depth 1 https://github.com/fcitx-contrib/fcitx5-ios.git "$src/fcitx5-ios"
git -C "$src/fcitx5-ios" rev-parse HEAD >/dev/null
[[ -d "$src/fcitx5-keyboard-layouts" ]] || git clone --quiet --depth 1 \
    https://github.com/fcitx-contrib/fcitx5-keyboard-layouts.git "$src/fcitx5-keyboard-layouts"
out="$root/build/fcitxui"
rm -rf "$out" "$root/build/fcitxui-res"
mkdir -p "$out" "$root/build/fcitxui-res/share"
cp "$src/fcitx5-ios/uipanel/"*.swift "$out/"
rm -f "$out/Clipboard.swift"   # history view: needs GRDB and a store
cp "$src/fcitx5-ios/protocol/FcitxProtocol.swift" "$src/fcitx5-ios/common/logging.swift" \
   "$src/fcitx5-ios/common/ClipboardSuggestion.swift" "$out/"
# The keyboard's undo and redo, and the line helpers it uses (app/KeyboardSwiftUI/DocumentEditing.swift).
cp "$src/fcitx5-ios/keyboard/UndoRedo.swift" "$src/fcitx5-ios/keyboard/util.swift" "$out/"
sed -i '' -E '/^import (Fcitx|FcitxIpc|FcitxProtocol|SwiftUtil|UIPanel)$/d' "$out/"*.swift
cp -R "$src/fcitx5-keyboard-layouts/layout" "$src/fcitx5-keyboard-layouts/symbol" "$root/build/fcitxui-res/share/"
ls "$out" | wc -l
