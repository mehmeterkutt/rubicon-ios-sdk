#!/usr/bin/env bash
# Documentation on every public symbol (D13), the counterpart of the Dokka check: reads the symbol
# graph and fails when a public symbol has no documentation comment. With --build it also runs
# `xcodebuild docbuild` so the DocC archive is known to build (simulator lane, nightly).
set -euo pipefail

cd "$(dirname "$0")/.."
# dump-symbol-graph walks every module, test hosts included, so they must be built first; the
# output directory differs between SwiftPM's build systems, so it is read from the command's output.
swift build --build-tests > /dev/null
dir=$(swift package dump-symbol-graph --minimum-access-level public --skip-synthesized-members 2>&1 \
    | sed -n 's/^Files written to //p' | tail -1)
[ -n "$dir" ] && [ -d "$dir" ] || { echo "symbol graph: no output directory" >&2; exit 1; }

python3 - "$dir" <<'PY'
import json, sys, os
missing = []
for m in ("RubiconCore", "Rubicon", "RubiconObjC"):
    g = json.load(open(os.path.join(sys.argv[1], f"{m}.symbols.json")))
    for s in g.get("symbols", []):
        if s.get("spi") or s.get("accessLevel") not in ("public", "open"):
            continue
        # Re-exported and synthesized symbols carry another module's or no location: not ours to document.
        if f"/Sources/{m}/" not in s.get("location", {}).get("uri", ""):
            continue
        if not s.get("docComment", {}).get("lines"):
            loc = s.get("location", {})
            uri = loc.get("uri", "").replace("file://", "")
            line = loc.get("position", {}).get("line", 0) + 1
            missing.append(f"{uri}:{line}: {'.'.join(s['pathComponents'])} has no documentation comment")
if missing:
    print("\n".join(missing))
    print(f"docs: {len(missing)} undocumented public symbol(s)", file=sys.stderr)
    sys.exit(1)
print("docs: every public symbol is documented")
PY

if [ "${1:-}" = "--build" ]; then
    xcodebuild docbuild -scheme Rubicon -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath .build/docc -quiet
    echo "docs: DocC archive built"
fi
