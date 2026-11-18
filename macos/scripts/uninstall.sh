#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
control="$root/build/${CASSOTIS_ARCH:-arm64}/bin/cassotis-input-source"
if [[ -d "$root/Cassotis.app" ]]; then control="$root/tools/cassotis-input-source"; fi
app="$HOME/Library/Input Methods/CassotisIME.app"
legacy="$HOME/Library/Input Methods/Cassotis.app"
if [[ ! -e "$app" && ! -L "$app" ]]; then app="$legacy"; fi
[[ $# -eq 0 || ( $# -eq 1 && "$1" == --require-disabled ) ]] || { echo 'Usage: uninstall.sh [--require-disabled]' >&2; exit 2; }
[[ ! -L "$app" ]] || { echo 'Application path is a symlink.' >&2; exit 1; }
[[ -d "$app" ]] || { echo '当前用户尚未安装言泉输入法。'; exit 0; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" =~ ^(com\.hustmobile|org\.cassotis)\.inputmethod\.Cassotis$ ]] || {
    echo 'Refusing to remove a different application at Cassotis.app.' >&2; exit 1;
}
if [[ "${1:-}" == --require-disabled ]]; then
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
    source_status="$("$control" status-id "$bundle_id" || true)"
    if [[ "$source_status" == *' enabled=1 '* ]]; then
        echo '请先在“系统设置 → 键盘 → 文字输入 → 编辑”中移除言泉输入法，再点击重试卸载。' >&2
        exit 3
    fi
fi
"$control" prepare-update
# User enablement belongs to System Settings. Disabling through TIS can alter
# menu ordering even when macOS refuses the protected preference write.
if [[ -x /usr/bin/trash ]]; then
    /usr/bin/trash "$app"
else
    # Older macOS releases do not ship the trash command.
    mv "$app" "$HOME/.Trash/Cassotis-$(uuidgen).app"
fi
[[ ! -e "$app" ]] || { echo '应用仍在输入法目录中。' >&2; exit 1; }
printf '言泉输入法已移入废纸篓。词库和设置已保留。\n'
printf '如果系统设置的输入源列表中仍有言泉输入法，请选中它并点击“-”移除该输入源。\n'
