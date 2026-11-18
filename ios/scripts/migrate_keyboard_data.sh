#!/usr/bin/env bash
# CASSOTIS_DEVICE=<phone> migrate_keyboard_data.sh [label] [--install CassotisPOC.app]
set -euo pipefail
exec python3 -B "$(dirname "$0")/migrate_keyboard_data.py" "$@"
