#!/usr/bin/env bash
# Copies the Android golden wire files, the contract (Serialization 5), into the core test fixtures.
# Usage: refresh-golden.sh [--check]   ANDROID_SDK_DIR overrides ~/Projects/rubicon-android-sdk.
set -euo pipefail

cd "$(dirname "$0")/.."
src=${ANDROID_SDK_DIR:-$HOME/Projects/rubicon-android-sdk}/sdk-core/src/test/resources/golden
dst=Tests/RubiconCoreTests/Fixtures/golden
[ -d "$src" ] || { echo "golden: Android golden directory not found at $src" >&2; exit 1; }
if [ "${1:-}" = "--check" ]; then
    diff -r "$src" "$dst" && echo "golden: identical to Android"
    exit $?
fi
mkdir -p "$dst"
rm -f "$dst"/*.json
cp "$src"/*.json "$dst"/
echo "golden: $(ls "$dst" | wc -l | tr -d ' ') files copied from $src"
