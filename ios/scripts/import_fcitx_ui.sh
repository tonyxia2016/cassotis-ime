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
# Compute on key-down: the panel sends a key when the finger lifts. Two calls let the
# keyboard start at touch-down and learn when a long press or a swipe drops the press
# (app/KeyboardSwiftUI/FcitxBackend.swift). Each anchor must occur once, or upstream
# moved and the patch is refused rather than silently lost.
python3 -I - "$out" <<'PY'
import pathlib, sys
out = pathlib.Path(sys.argv[1])
def patch(name, old, new):
    path = out / name
    text = path.read_text()
    if text.count(old) != 1:
        sys.exit(f"import_fcitx_ui.sh: {name} changed upstream; the key-down patch does not apply")
    path.write_text(text.replace(old, new))
patch("Key.swift",
      "          onOrderedKeyPress: {\n            return {\n",
      "          onOrderedKeyPress: {\n            keyDownHook(key, code, forward)  // Cassotis: compute on key-down\n"
      "            return {\n")
patch("VirtualKeyboard.swift",
      "  func removeOrderedKeyPress(_ id: Int) {\n    orderedKeyPresses.removeValue(forKey: id)\n",
      "  func removeOrderedKeyPress(_ id: Int) {\n"
      "    if let press = orderedKeyPresses[id], !press.sent { keyCancelHook() }  // Cassotis: dropped unsent\n"
      "    orderedKeyPresses.removeValue(forKey: id)\n")
PY
sed -i '' -E '/^import (Fcitx|FcitxIpc|FcitxProtocol|SwiftUtil|UIPanel)$/d' "$out/"*.swift
cp -R "$src/fcitx5-keyboard-layouts/layout" "$src/fcitx5-keyboard-layouts/symbol" "$root/build/fcitxui-res/share/"
ls "$out" | wc -l
