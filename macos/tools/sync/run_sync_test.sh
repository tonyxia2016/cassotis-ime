#!/usr/bin/env bash
# Build and run the sync merge tests (tools/sync/sync_test.cpp): replicas are user
# dictionaries in a temporary directory, batches go from one to another directly.
#   run_sync_test.sh [user_dict.db]   with a database: also time one sync of a copy of it
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/cassotis-sync-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
xcrun clang++ -std=c++17 -O2 -g -Wall -Wextra -Werror -I"$root/src/sync" \
    "$root/src/sync/SyncStore.cpp" "$root/tools/sync/sync_test.cpp" -lsqlite3 -lcompression \
    -o "$work/sync_test"
"$work/sync_test" "$work" "$@"
