#!/usr/bin/env python3
"""Prints the udid of the newest available iPhone simulator, or of the newest runtime of the iOS
major version given as the first argument (nightly matrix, D11). Reads `simctl list` from stdin;
describes the choice on stderr."""
import json
import sys

major = sys.argv[1] if len(sys.argv) > 1 else ""
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
print(best[1])
print(f"simulator: {best[2]} on {best[3]}", file=sys.stderr)
