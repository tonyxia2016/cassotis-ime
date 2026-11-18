#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
arch="${CASSOTIS_ARCH:-arm64}"
source_app="$root/build/$arch/Cassotis.app"
destination="$HOME/Library/Input Methods/CassotisIME.app"
legacy="$HOME/Library/Input Methods/Cassotis.app"
control="$root/build/$arch/bin/cassotis-input-source"
if [[ -d "$root/Cassotis.app" ]]; then
    source_app="$root/Cassotis.app"
    control="$root/tools/cassotis-input-source"
fi
[[ -d "$source_app" ]] || "$root/scripts/build.sh"
codesign --verify --deep --strict "$source_app"
for existing in "$destination" "$legacy"; do
    [[ ! -L "$existing" ]] || { echo "Installed application path is a symlink: $existing" >&2; exit 1; }
    if [[ -d "$existing" ]]; then
        [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$existing/Contents/Info.plist")" =~ ^(com\.hustmobile|org\.cassotis)\.inputmethod\.Cassotis$ ]] || {
            echo "Refusing to replace a different application at $existing." >&2; exit 1;
        }
    fi
done
mkdir -p "$HOME/Library/Input Methods"
staging="$(mktemp -d "$HOME/Library/Input Methods/.cassotis-install.XXXXXX")"
previous_app="$staging/previous"
previous_legacy="$staging/legacy"
installed=0
previous_source="$("$control" current)"
cleanup() {
    local status=$?
    if [[ $status -ne 0 ]]; then
        if [[ $installed -ne 0 ]]; then
            # Registration-only did not enable or disable any input source.
            # Preserve the user's state and menu order when restoring the app.
            "$control" prepare-update >/dev/null || true
            mv "$destination" "$staging/failed.app"
        fi
        if [[ -d "$previous_app" ]]; then
            mv "$previous_app" "$destination"
            "$control" register-only "$destination" >/dev/null || true
        fi
        if [[ -d "$previous_legacy" ]]; then
            mv "$previous_legacy" "$legacy"
            "$control" register-only "$legacy" >/dev/null || true
        fi
        if [[ -d "$destination" || -d "$legacy" ]]; then "$control" launch >/dev/null || true; fi
    fi
    if [[ $status -eq 0 && "$previous_source" == org.cassotis.inputmethod.Cassotis ]]; then
        previous_source=com.hustmobile.inputmethod.Cassotis
    fi
    if [[ -n "$previous_source" ]]; then "$control" select-id "$previous_source" >/dev/null || true; fi
    rm -rf "$staging"
    return "$status"
}
trap cleanup EXIT
# Deploy the verified files without inheriting the download's extended
# attributes. --noqtn alone still copies an explicit quarantine xattr on macOS.
# Inheriting it would translocate the input method away from its registered path.
ditto --noextattr --noqtn "$source_app" "$staging/Cassotis.app"
codesign --verify --deep --strict "$staging/Cassotis.app"
dictionary="$HOME/Library/Application Support/CassotisIME/user_dict.db"
backup_directory="$HOME/Library/Application Support/CassotisIME/Backups"
dictionary_backup=''
if [[ -d "$legacy" && -f "$dictionary" ]]; then
    mkdir -p "$backup_directory"
    dictionary_backup="$backup_directory/Before-App-ID-$(date +%Y%m%d-%H%M%S)-$(uuidgen).sqlite"
    "$control" backup-dictionary "$dictionary" "$dictionary_backup"
    printf 'Verified dictionary backup: %s\n' "$dictionary_backup"
fi
"$control" prepare-update
if [[ -n "$dictionary_backup" ]]; then "$control" import-dictionary "$dictionary_backup" "$dictionary"; fi
# A new App ID at the legacy URL can remain associated with the old keyboard
# in the current login session. Keep the replaced directories in staging
# only until registration and launch succeed, so a failure can be rolled back.
if [[ -d "$legacy" ]]; then mv "$legacy" "$previous_legacy"; fi
if [[ -d "$destination" ]]; then mv "$destination" "$previous_app"; fi
mv "$staging/Cassotis.app" "$destination"
installed=1
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination"
"$control" register-only "$destination"
# Finish LaunchServices verification of the new executable before restoring
# the input source. macOS can discard a first key while launching a replacement
# input method; the frontend can buffer keys once its IMK server is running.
"$control" launch
# Keyboard Settings keeps its own input-source index. After an App ID or
# bundle path change it can still resolve Cassotis to its removed URL even
# when TIS in the installer already reports the new input source as enabled.
refresh_keyboard_settings_index() {
    local cache="$1" index file
    [[ -n "$cache" ]] || return 1
    cache="${cache%/}/com.apple.Keyboard-Settings.extension"
    index="$cache/com.apple.IntlDataCache.le.kbdx"
    [[ -f "$index" && ! -L "$index" ]] || return 0
    LC_ALL=C /usr/bin/grep -aFq -- "$legacy" "$index" || return 0
    if LC_ALL=C /usr/bin/grep -aFq -- "$destination" "$index"; then return 0; fi
    for file in "$index" "$cache/com.apple.IntlDataCache.le"; do
        if [[ -f "$file" && ! -L "$file" ]]; then
            mv "$file" "$staging/" || return 1
        fi
    done
    printf '键盘设置将重新读取言泉的安装位置。如果系统设置已打开，请退出后重新打开。\n'
}
refresh_keyboard_settings_index "$(/usr/bin/getconf DARWIN_USER_CACHE_DIR)" ||
    printf '键盘设置索引暂时无法刷新。请重新打开键盘设置查看输入源。\n' >&2
printf 'Installed: %s\n' "$destination"
cat <<'INSTRUCTIONS'
应用文件已安装。图形安装器会继续请求 macOS 启用言泉输入法。
若使用命令行安装，或图形安装器提示尚未启用：
打开“系统设置 → 键盘 → 文字输入 → 编辑”。
若输入源列表中没有言泉输入法，点击“+”，在“中文（简体）”中添加。
按 macOS 的提示确认允许使用言泉输入法。
若列表中已有言泉输入法，但输入菜单中没有，请在系统设置中移除该输入源后重新添加。
完成系统确认后，从菜单栏的输入菜单选择言泉输入法；选中时显示彩色言泉 logo。
Input-source approval is requested by the graphical installer after deployment.
INSTRUCTIONS
