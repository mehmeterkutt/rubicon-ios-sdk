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

swift package dump-symbol-graph --minimum-access-level public --skip-synthesized-members > /dev/null
dir=.build/out/symbolgraph
[ -d "$dir" ] || dir=$(find .build -type d -name symbolgraph | head -1)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for m in $modules; do
    python3 - "$dir/$m.symbols.json" > "$tmp/$m.txt" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
lines = []
for s in g.get("symbols", []):
    if s.get("spi"):
        continue
    if s.get("accessLevel") not in ("public", "open"):
        continue
    decl = "".join(f["spelling"] for f in s.get("declarationFragments", []))
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
