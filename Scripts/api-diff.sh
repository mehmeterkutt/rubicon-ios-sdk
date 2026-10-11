#!/usr/bin/env bash
# The public API record and diff (iOS Public API 8), the counterpart of apiDump and apiCheck.
#   api-diff.sh           compare the public symbols of the library products with API/*.txt and,
#                         when a release tag exists, run diagnose-api-breaking-changes against it
#   api-diff.sh --update  rewrite API/*.txt after an intended public API change (commit the result)
# `package` symbols are not public and never appear; SPI symbols, should one ever exist, are skipped too.
set -euo pipefail

cd "$(dirname "$0")/.."
mode=${1:-check}
modules="RubiconCore Rubicon RubiconObjC"

# dump-symbol-graph walks every module, test hosts included, so they must be built first; the
# output directory differs between SwiftPM's build systems, so it is read from the command's output.
swift build --build-tests > /dev/null
dir=$(swift package dump-symbol-graph --minimum-access-level public --skip-synthesized-members 2>&1 \
    | sed -n 's/^Files written to //p' | tail -1)
[ -n "$dir" ] && [ -d "$dir" ] || { echo "symbol graph: no output directory" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for m in $modules; do
    python3 - "$dir/$m.symbols.json" > "$tmp/$m.txt" <<'PY'
import json, re, sys
g = json.load(open(sys.argv[1]))
module = g["module"]["name"]
lines = []
for s in g.get("symbols", []):
    if s.get("spi"):
        continue
    if s.get("accessLevel") not in ("public", "open"):
        continue
    # Re-exported and synthesized symbols carry another module's or no location: not this record.
    uri = s.get("location", {}).get("uri", "")
    if f"/Sources/{module}/" not in uri:
        continue
    decl = "".join(f["spelling"] for f in s.get("declarationFragments", []))
    # Toolchains disagree on closure typealiases: Xcode 27 spells the unlabeled parameter names
    # (`_ level: LogLevel`), Xcode 26 does not. The names are not callable API, so they are dropped
    # here and the record reads the same under both.
    if s["kind"]["identifier"] == "swift.typealias":
        decl = re.sub(r"\b_ [A-Za-z_][A-Za-z0-9_]*: ", "", decl)
    path = ".".join(s["pathComponents"])
    lines.append(f"{s['kind']['identifier']} {path}: {decl}")
sys.stdout.write("".join(line + "\n" for line in sorted(set(lines))))
PY
done

mkdir -p API
if [ "$mode" = "--update" ]; then
    for m in $modules; do cp "$tmp/$m.txt" "API/$m.txt"; done
    echo "api: API/*.txt updated; review and commit"
    exit 0
fi

changed=0
for m in $modules; do
    [ -f "API/$m.txt" ] || : > "API/$m.txt"
    if ! diff -u "API/$m.txt" "$tmp/$m.txt" > "$tmp/$m.diff"; then
        echo "api: public API of $m differs from API/$m.txt (run Scripts/api-diff.sh --update if intended):"
        cat "$tmp/$m.diff"
        changed=1
    fi
done

tag=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
if [ -n "$tag" ]; then
    echo "api: breaking changes against $tag"
    swift package diagnose-api-breaking-changes "$tag" --products Rubicon RubiconObjC \
        --breakage-allowlist-path Scripts/api-breakage-allowlist.txt || changed=1
else
    echo "api: no release tag yet, breaking-change diagnosis skipped"
fi
[ "$changed" -eq 0 ] && echo "api: ok"
exit "$changed"
