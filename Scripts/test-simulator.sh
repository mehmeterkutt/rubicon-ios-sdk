#!/usr/bin/env bash
# The simulator suite: RubiconTests (Swift Testing) and RubiconObjCTests (XCTest) through xcodebuild.
# Usage: test-simulator.sh [ios-major]   picks the newest available iPhone runtime, or the newest
# runtime of the given major version (nightly matrix, D11).
set -euo pipefail

cd "$(dirname "$0")/.."
major=${1:-}
udid=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
major = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
best = None
for runtime, items in devices.items():
    if "iOS" not in runtime:
        continue
    version = tuple(int(p) for p in runtime.rsplit("iOS-", 1)[1].split("-"))
    if major and version[0] != int(major):
        continue
    for d in items:
        if d["name"].startswith("iPhone") and (best is None or version > best[0]):
            best = (version, d["udid"], d["name"], runtime)
if best is None:
    sys.exit(f"no available iPhone simulator for iOS {major or 'any'}")
print(best[1], file=sys.stdout)
print(f"simulator: {best[2]} on {best[3]}", file=sys.stderr)
' "$major")
xcodebuild test -scheme Rubicon-Package -destination "id=$udid" -derivedDataPath .build/xcode \
    -only-testing:RubiconTests -only-testing:RubiconObjCTests -quiet
echo "simulator tests: ok"
