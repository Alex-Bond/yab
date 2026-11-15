#!/bin/bash
# What a sync flush costs the main thread, on a copy of a journal:
#   ./farm exec --host main -- bash evals/sync-cost/run.sh /path/to/sync.sqlite [ROUNDS]
# Pinned to the Mac whose journal it reads: the copy never leaves it.
set -euo pipefail
cd "$(dirname "$0")/../.."
source="${1:?a sync.sqlite to copy}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# A consistent copy, write-ahead log and all, so the bench's writes land in it.
sqlite3 "$source" ".backup '$work/sync.sqlite'"
swiftc -O -module-name SyncBench Sources/SyncKit/*.swift evals/sync-cost/main.swift -lsqlite3 -o "$work/bench" 2>&1 | tee "$work/build.log"
"$work/bench" "$work/sync.sqlite" "${2:-15}"
