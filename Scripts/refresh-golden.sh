#!/usr/bin/env bash
# Copies the Android golden wire files, the contract (Serialization 5), into the core test fixtures
# and records their digest. The digest is what CI checks: the copies must match it, and when the
# Android repository is present, its files must still produce it (step 8.4).
# Usage: refresh-golden.sh            copy and record
#        refresh-golden.sh --check    verify; ANDROID_SDK_DIR overrides ~/Projects/rubicon-android-sdk
set -euo pipefail

cd "$(dirname "$0")/.."
src=${ANDROID_SDK_DIR:-$HOME/Projects/rubicon-android-sdk}/sdk-core/src/test/resources/golden
dst=Tests/RubiconCoreTests/Fixtures/golden
digest_file="$dst/SOURCE.sha256"

digest() {
    # The digest of the sorted file names and contents, independent of the directory.
    (cd "$1" && for f in $(ls *.json | sort); do printf '%s\n' "$f"; cat "$f"; done) | shasum -a 256 | cut -d' ' -f1
}

if [ "${1:-}" = "--check" ]; then
    [ -f "$digest_file" ] || { echo "golden: $digest_file is missing; run refresh-golden.sh" >&2; exit 1; }
    recorded=$(cat "$digest_file")
    if [ "$(digest "$dst")" != "$recorded" ]; then
        echo "golden: the copies in $dst do not match $digest_file; run refresh-golden.sh, never edit a copy" >&2
        exit 1
    fi
    if [ -d "$src" ]; then
        if [ "$(digest "$src")" != "$recorded" ]; then
            echo "golden: the Android files at $src changed; run refresh-golden.sh and fix what the tests say" >&2
            exit 1
        fi
        echo "golden: copies match the recorded digest and the Android files"
    else
        echo "golden: copies match the recorded digest (Android repository not present, not compared)"
    fi
    exit 0
fi

[ -d "$src" ] || { echo "golden: Android golden directory not found at $src" >&2; exit 1; }
mkdir -p "$dst"
for f in "${dst:?}"/*.json; do [ -e "$f" ] && rm -f "$f"; done
cp "$src"/*.json "$dst"/
digest "$dst" > "$digest_file"
echo "golden: $(ls "$dst"/*.json | wc -l | tr -d ' ') files copied from $src; digest $(cat "$digest_file")"
