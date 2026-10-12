#!/usr/bin/env bash
# The simulator suite: RubiconTests (Swift Testing) and RubiconObjCTests (XCTest) through xcodebuild.
# Usage: test-simulator.sh [ios-major]   picks the newest available iPhone runtime, or the newest
# runtime of the given major version (nightly matrix, D11).
set -euo pipefail

cd "$(dirname "$0")/.."
major=${1:-}
udid=$(xcrun simctl list devices available -j | python3 Scripts/lib/pick-simulator.py "$major")
# Without `-collect-test-diagnostics never` a failing test makes xcodebuild run `simctl diagnose`
# for up to ten minutes before it reports (plan section 15, step 7.2).
xcodebuild test -scheme Rubicon-Package -destination "id=$udid" -derivedDataPath .build/xcode \
    -only-testing:RubiconTests -only-testing:RubiconObjCTests -collect-test-diagnostics never \
    -enableCodeCoverage YES -quiet
echo "simulator tests: ok"

# The Rubicon target's coverage gate (D9, 80 percent) is measured here: the macOS export of
# `swift test` holds the core only (plan section 15, step 7.2).
result=$(ls -td .build/xcode/Logs/Test/*.xcresult | head -1)
xcrun xccov view --report --json "$result" | python3 -c '
import json, sys
report = json.load(sys.stdin)
gates = {"Sources/Rubicon/": 80.0, "Sources/RubiconObjC/": None}
totals = {k: [0, 0] for k in gates}
seen = set()
# A source file appears under every target that links it; count it once.
for target in report.get("targets", []):
    for f in target.get("files", []):
        if f["path"] in seen:
            continue
        seen.add(f["path"])
        for prefix in gates:
            if "/" + prefix in f["path"]:
                totals[prefix][0] += f["executableLines"]
                totals[prefix][1] += f["coveredLines"]
                break
failed = False
for prefix, (count, covered) in totals.items():
    if count == 0:
        print(f"coverage: {prefix} has no lines in the simulator run")
        continue
    pct = 100.0 * covered / count
    gate = gates[prefix]
    if gate is None:
        print(f"coverage: {prefix} {pct:.1f}% of {count} lines (no gate: forwarding code, D9)")
        continue
    ok = pct >= gate
    failed |= not ok
    verdict = "ok" if ok else "BELOW GATE"
    print(f"coverage: {prefix} {pct:.1f}% of {count} lines (gate {gate:.0f}%) {verdict}")
sys.exit(1 if failed else 0)
'
