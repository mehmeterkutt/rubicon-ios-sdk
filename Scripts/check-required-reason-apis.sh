#!/usr/bin/env bash
# The privacy manifest grep (iOS Privacy 1): the symbols of Apple's required-reason API categories
# may appear only under Sources/Rubicon/Platform, and only for the two declared categories
# (system boot time 35F9.1, file timestamp C617.1). Comments and strings are blanked first.
# Usage: check-required-reason-apis.sh [root]
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=${1:-$(cd "$here/.." && pwd)}
allowed="Sources/Rubicon/Platform/"

# extended regex ~ category ~ declared (yes/no)
symbols=$(cat <<'SYMBOLS'
systemUptime~NSPrivacyAccessedAPICategorySystemBootTime~yes
mach_absolute_time~NSPrivacyAccessedAPICategorySystemBootTime~yes
mach_continuous_time~NSPrivacyAccessedAPICategorySystemBootTime~yes
creationDate~NSPrivacyAccessedAPICategoryFileTimestamp~yes
contentModificationDate~NSPrivacyAccessedAPICategoryFileTimestamp~yes
attributesOfItem~NSPrivacyAccessedAPICategoryFileTimestamp~yes
fileModificationDate~NSPrivacyAccessedAPICategoryFileTimestamp~yes
\bstat[[:space:]]*\(~NSPrivacyAccessedAPICategoryFileTimestamp~yes
\bfstat[[:space:]]*\(~NSPrivacyAccessedAPICategoryFileTimestamp~yes
\blstat[[:space:]]*\(~NSPrivacyAccessedAPICategoryFileTimestamp~yes
getattrlist~NSPrivacyAccessedAPICategoryFileTimestamp~yes
volumeAvailableCapacity~NSPrivacyAccessedAPICategoryDiskSpace~no
systemFreeSize~NSPrivacyAccessedAPICategoryDiskSpace~no
statfs~NSPrivacyAccessedAPICategoryDiskSpace~no
UserDefaults~NSPrivacyAccessedAPICategoryUserDefaults~no
activeInputModes~NSPrivacyAccessedAPICategoryActiveKeyboards~no
SYMBOLS
)

violations=0
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

if [ "$violations" -gt 0 ]; then
    echo "required-reason APIs: $violations violation(s)" >&2
    exit 1
fi
echo "required-reason APIs: ok"
