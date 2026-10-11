#!/usr/bin/env bash
# Line coverage gate (D9): 90 percent in RubiconCore, 80 percent in Rubicon, from the llvm-cov
# export that `swift test --enable-code-coverage` produces. Runs the tests unless --no-test is given.
set -euo pipefail

cd "$(dirname "$0")/.."
if [ "${1:-}" != "--no-test" ]; then
    swift test --enable-code-coverage
fi
json=$(swift test --show-codecov-path)
[ -f "$json" ] || { echo "coverage: no export at $json" >&2; exit 1; }

python3 - "$json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
gates = {"Sources/RubiconCore/": 90.0, "Sources/Rubicon/": 80.0}
totals = {k: [0, 0] for k in gates}
for f in data["data"][0]["files"]:
    name = f["filename"]
    for prefix in gates:
        if ("/" + prefix) in name:
            s = f["summary"]["lines"]
            totals[prefix][0] += s["count"]
            totals[prefix][1] += s["covered"]
            break
failed = False
for prefix, (count, covered) in totals.items():
    if count == 0:
        print(f"coverage: {prefix} has no lines yet")
        continue
    pct = 100.0 * covered / count
    ok = pct >= gates[prefix]
    failed |= not ok
    print(f"coverage: {prefix} {pct:.1f}% of {count} lines (gate {gates[prefix]:.0f}%) {'ok' if ok else 'BELOW GATE'}")
sys.exit(1 if failed else 0)
PY
