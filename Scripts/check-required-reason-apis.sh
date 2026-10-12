#!/usr/bin/env bash
# The privacy manifest grep (iOS Privacy 1): the symbols of Apple's required-reason API categories
# may appear only under Sources/Rubicon/Platform, and only for the two declared categories
# (system boot time 35F9.1, file timestamp C617.1). Comments and strings are blanked first. The
# symbol list is Apple's (NSPrivacyAccessedAPIType, fetched 2026-10-12) in regular-expression form.
# Usage: check-required-reason-apis.sh [root]
#        check-required-reason-apis.sh --self-test
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
allowed="Sources/Rubicon/Platform/"

# extended regex ~ category ~ declared (yes/no)
symbols=$(cat <<'SYMBOLS'
systemUptime~NSPrivacyAccessedAPICategorySystemBootTime~yes
mach_absolute_time~NSPrivacyAccessedAPICategorySystemBootTime~yes
mach_continuous_time~NSPrivacyAccessedAPICategorySystemBootTime~yes
creationDate~NSPrivacyAccessedAPICategoryFileTimestamp~yes
contentModificationDate~NSPrivacyAccessedAPICategoryFileTimestamp~yes
\bmodificationDate~NSPrivacyAccessedAPICategoryFileTimestamp~yes
fileModificationDate~NSPrivacyAccessedAPICategoryFileTimestamp~yes
attributesOfItem~NSPrivacyAccessedAPICategoryFileTimestamp~yes
\bstat[[:space:]]*\(~NSPrivacyAccessedAPICategoryFileTimestamp~yes
\bl?f?stat(at)?[[:space:]]*\(~NSPrivacyAccessedAPICategoryFileTimestamp~yes
getattrlist~NSPrivacyAccessedAPICategoryFileTimestamp~yes
volumeAvailableCapacity~NSPrivacyAccessedAPICategoryDiskSpace~no
volumeTotalCapacity~NSPrivacyAccessedAPICategoryDiskSpace~no
systemFreeSize~NSPrivacyAccessedAPICategoryDiskSpace~no
\bsystemSize~NSPrivacyAccessedAPICategoryDiskSpace~no
f?statv?fs[[:space:]]*\(~NSPrivacyAccessedAPICategoryDiskSpace~no
UserDefaults~NSPrivacyAccessedAPICategoryUserDefaults~no
activeInputModes~NSPrivacyAccessedAPICategoryActiveKeyboards~no
SYMBOLS
)

run() {
    local root=$1 violations=0
    while IFS= read -r file; do
        rel=${file#"$root"/}
        stripped=$(perl "$here/lib/strip-swift.pl" < "$file")
        while IFS='~' read -r symbol category declared; do
            [ -z "$symbol" ] && continue
            hits=$(grep -nE "$symbol" <<< "$stripped" | cut -d: -f1 || true)
            [ -z "$hits" ] && continue
            for line in $hits; do
                if [ "$declared" = no ]; then
                    echo "$rel:$line: $category is not declared in PrivacyInfo.xcprivacy; its APIs are not used (iOS Privacy 1)"
                    violations=$((violations + 1))
                elif [[ "$rel" != "$allowed"* ]]; then
                    echo "$rel:$line: $category API outside $allowed (iOS Privacy 1)"
                    violations=$((violations + 1))
                fi
            done
        done <<< "$symbols"
    done < <(find "$root/Sources" \( -name '*.swift' -o -name '*.m' -o -name '*.h' \) -type f | sort)
    return "$violations"
}

if [ "${1:-}" = "--self-test" ]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/Sources/RubiconCore" "$tmp/Sources/Rubicon/Platform" "$tmp/Sources/RubiconObjC"
    cat > "$tmp/Sources/RubiconCore/Bad.swift" <<'SWIFT'
// systemUptime and UserDefaults in a comment are fine; "creationDate" in a string is fine.
let a = ProcessInfo.processInfo.systemUptime
let b = UserDefaults.standard
let c = try url.resourceValues(forKeys: [.creationDateKey])
let d = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
var s = stat(); _ = stat(path, &s)
SWIFT
    cat > "$tmp/Sources/Rubicon/Platform/Good.swift" <<'SWIFT'
let a = ProcessInfo.processInfo.systemUptime
let c = try url.resourceValues(forKeys: [.creationDateKey])
let bad = UIApplication.shared.activeInputModes
let worse = try url.resourceValues(forKeys: [.volumeTotalCapacityKey])
SWIFT
    cat > "$tmp/Sources/RubiconObjC/Wrap.m" <<'OBJC'
// NSUserDefaults in a comment
NSDate *when = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileModificationDate;
OBJC
    out=$(run "$tmp" || true)
    expected=$(cat <<'EXPECTED'
Sources/Rubicon/Platform/Good.swift:3: NSPrivacyAccessedAPICategoryActiveKeyboards
Sources/Rubicon/Platform/Good.swift:4: NSPrivacyAccessedAPICategoryDiskSpace
Sources/RubiconCore/Bad.swift:2: NSPrivacyAccessedAPICategorySystemBootTime
Sources/RubiconCore/Bad.swift:3: NSPrivacyAccessedAPICategoryUserDefaults
Sources/RubiconCore/Bad.swift:4: NSPrivacyAccessedAPICategoryFileTimestamp
Sources/RubiconCore/Bad.swift:5: NSPrivacyAccessedAPICategoryDiskSpace
Sources/RubiconCore/Bad.swift:6: NSPrivacyAccessedAPICategoryFileTimestamp
Sources/RubiconObjC/Wrap.m:2: NSPrivacyAccessedAPICategoryFileTimestamp
EXPECTED
)
    actual=$(sed -E 's/^([^:]+:[0-9]+): ([A-Za-z]+) .*/\1: \2/' <<< "$out" | sort -u)
    expected=$(sort -u <<< "$expected")
    if [ "$actual" = "$expected" ]; then
        echo "required-reason APIs self-test: ok"
        exit 0
    fi
    echo "required-reason APIs self-test: mismatch"
    diff <(echo "$expected") <(echo "$actual") || true
    exit 1
fi

root=${1:-$(cd "$here/.." && pwd)}
if out=$(run "$root"); then
    echo "required-reason APIs: ok"
else
    echo "$out"
    echo "required-reason APIs: $(wc -l <<< "$out" | tr -d ' ') violation(s)" >&2
    exit 1
fi
