#!/usr/bin/env bash
# The static source rules of plan section 5, the counterpart of Android's checkSourceRules.
# Comments and string literals are blanked first (Scripts/lib/strip-swift.pl), so documentation may
# name what a rule forbids. Usage: check-source-rules.sh [root]   or   --self-test
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
strip="$here/lib/strip-swift.pl"
root=${1:-$(cd "$here/.." && pwd)}

# id ~ extended regex ~ scope ~ paths allowed to match (space separated, prefix match) ~ reason
# scope: all = every file under Sources; core = only Sources/RubiconCore; log = inside log calls
rules=$(cat <<'RULES'
no-print~\b(print|debugPrint|NSLog)[[:space:]]*\(~all~~Log only through the SDK logger, never print (iOS Logging 1).
no-user-defaults~\bUserDefaults\b~all~~UserDefaults is a required-reason API and not the SDK's store (iOS Privacy 1, iOS Disk 1).
no-shared-session~URLSession[[:space:]]*\.[[:space:]]*shared~all~~The SDK owns its own ephemeral session (iOS HTTP 1).
no-available~#(un)?available\b~all~~iOS 15 is the floor; an availability check is a design discussion (iOS Public API 2).
no-date-now-in-core~\bDate[[:space:]]*\([[:space:]]*\)|\bDate\.now\b~core~~Time comes from the Clock protocol, never the system directly, so tests can control it.
no-main-queue-in-core~DispatchQueue[[:space:]]*\.[[:space:]]*main\b~core~~The core never touches the main queue; the host app's threads are not ours.
no-uikit-outside-rubicon~\bimport[[:space:]]+UIKit\b~all~Sources/Rubicon/~UIKit lives only in the Rubicon target (iOS Public API 8).
no-async-public-api~\bpublic\b[^{]*\basync\b~all~~No async in the public API (iOS Public API 3).
no-task-public-api~\bpublic\b[^{]*\bTask[[:space:]]*[<{]~all~~No Task in public signatures (iOS Public API 3).
no-values-in-log~\b(properties|traits|userId|deviceId|apiKey|headers|body)\b~log~~Log lines never carry values, ids, keys, headers or bodies; log names, types and counts (Logging 4a).
RULES
)

violations=0

report() {
    echo "$1:$2: [$3] $4"
    violations=$((violations + 1))
}

allowed() {
    # $1 relative path, $2 space separated prefixes
    local rel=$1 prefixes=$2 p
    [ -z "$prefixes" ] && return 1
    for p in $prefixes; do
        case "$rel" in "$p"*) return 0 ;; esac
    done
    return 1
}

check_file() {
    local file=$1 rel=${1#"$root"/}
    local stripped
    stripped=$(perl "$strip" < "$file")
    while IFS='~' read -r id pattern scope allow reason; do
        [ -z "$id" ] && continue
        case "$scope" in
            core) case "$rel" in Sources/RubiconCore/*) ;; *) continue ;; esac ;;
        esac
        allowed "$rel" "$allow" && continue
        if [ "$scope" = log ]; then
            # Every log call (`log.<level>(` or `logger.<level>(`) and its balanced arguments.
            perl -e '
                sub balanced { my ($t, $j, $o, $c) = @_; my $d = 0;
                    while ($j < length $t) { my $ch = substr($t, $j, 1); $d++ if $ch eq $o; $d-- if $ch eq $c; $j++; last if $d == 0; } return $j; }
                local $/; my $t = <STDIN>; my $re = shift;
                while ($t =~ /\b(?:log|logger)\s*\.\s*(?:debug|info|warn|error)\s*[\({]/g) {
                    my $start = pos($t) - 1; my $j = $start;
                    $j = balanced($t, $j, "(", ")") if substr($t, $j, 1) eq "(";
                    my $k = $j; $k++ while $k < length $t && substr($t, $k, 1) =~ /\s/;
                    $j = balanced($t, $k, "{", "}") if substr($t, $k, 1) eq "{";
                    my $call = substr($t, $start, $j - $start);
                    if ($call =~ /$re/) { my $line = 1 + (substr($t, 0, $start) =~ tr/\n//); print "$line\n"; }
                }' "$pattern" <<< "$stripped" | while read -r line; do
                report "$rel" "$line" "$id" "$reason"
            done
            continue
        fi
        grep -nE "$pattern" <<< "$stripped" | cut -d: -f1 | while read -r line; do
            report "$rel" "$line" "$id" "$reason"
        done
    done <<< "$rules"

    # UIKit in the Rubicon target must be guarded so `swift build` on macOS compiles.
    case "$rel" in Sources/Rubicon/*)
        if grep -qE '\bimport[[:space:]]+UIKit\b' <<< "$stripped" && ! grep -qE '#if[[:space:]]+canImport\(UIKit\)' <<< "$stripped"; then
            report "$rel" "$(grep -nE '\bimport[[:space:]]+UIKit\b' <<< "$stripped" | head -1 | cut -d: -f1)" "unguarded-uikit" \
                "import UIKit must sit inside #if canImport(UIKit) (plan section 4)."
        fi ;;
    esac

    # @unchecked Sendable needs a justifying comment on the line above (iOS Public API 3).
    local n=0 prev=""
    while IFS= read -r line; do
        n=$((n + 1))
        if grep -qE '@unchecked[[:space:]]+Sendable' <<< "$line"; then
            if ! grep -qE '^[[:space:]]*//' <<< "$prev"; then
                report "$rel" "$n" "unjustified-unchecked-sendable" \
                    "@unchecked Sendable needs a comment on the line above saying what guards the state (iOS Public API 3)."
            fi
        fi
        prev=$line
    done < "$file"
}

run() {
    local count=0
    while IFS= read -r f; do
        count=$((count + 1))
        # Subshell counters do not propagate; collect output instead.
        check_file "$f"
    done < <(find "$root/Sources" \( -name '*.swift' -o -name '*.m' -o -name '*.h' \) -type f | sort)
    echo "source rules: $count files checked" >&2
}

if [ "${1:-}" = "--self-test" ]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/Sources/RubiconCore" "$tmp/Sources/Rubicon" "$tmp/Sources/Other"
    cat > "$tmp/Sources/RubiconCore/Bad.swift" <<'SWIFT'
// print( in a comment is fine; "print(" in a string is fine.
let a = Date()
let b = Date.now
DispatchQueue.main.async {}
let s = URLSession.shared
let d = UserDefaults.standard
print("x")
if #available(iOS 17, *) {}
public func fetch() async {}
public var task: Task<Void, Never>?
log.debug("user \(userId)")
logger.warn(.x, "count \(properties.count)")
log.info("names \(Array(properties.keys))")
log.warn(.code) { "key \(apiKey)" }
log.debug { "fine \(count)" }
final class Box: @unchecked Sendable {}
// guarded by `lock`
final class Good: @unchecked Sendable {}
SWIFT
    cat > "$tmp/Sources/Other/UI.swift" <<'SWIFT'
import UIKit
SWIFT
    cat > "$tmp/Sources/Rubicon/UI.swift" <<'SWIFT'
import UIKit
SWIFT
    cat > "$tmp/Sources/Rubicon/Clean.swift" <<'SWIFT'
#if canImport(UIKit)
    import UIKit
#endif
/// Uses `print` and `UserDefaults` only in this comment.
let when = Date()
DispatchQueue.main.async {}
log.debug("count \(properties.count)")
SWIFT
    out=$("$0" "$tmp" 2>/dev/null || true)
    expected=$(cat <<'EXPECTED'
Sources/Other/UI.swift:1: no-uikit-outside-rubicon
Sources/Rubicon/UI.swift:1: unguarded-uikit
Sources/RubiconCore/Bad.swift:2: no-date-now-in-core
Sources/RubiconCore/Bad.swift:3: no-date-now-in-core
Sources/RubiconCore/Bad.swift:4: no-main-queue-in-core
Sources/RubiconCore/Bad.swift:5: no-shared-session
Sources/RubiconCore/Bad.swift:6: no-user-defaults
Sources/RubiconCore/Bad.swift:7: no-print
Sources/RubiconCore/Bad.swift:8: no-available
Sources/RubiconCore/Bad.swift:9: no-async-public-api
Sources/RubiconCore/Bad.swift:10: no-task-public-api
Sources/RubiconCore/Bad.swift:11: no-values-in-log
Sources/RubiconCore/Bad.swift:12: no-values-in-log
Sources/RubiconCore/Bad.swift:13: no-values-in-log
Sources/RubiconCore/Bad.swift:14: no-values-in-log
Sources/RubiconCore/Bad.swift:16: unjustified-unchecked-sendable
Sources/Rubicon/Clean.swift:7: no-values-in-log
EXPECTED
)
    actual=$(sed -E 's/: \[([a-z-]+)\].*/: \1/' <<< "$out" | sort)
    expected=$(sort <<< "$expected")
    if [ "$actual" = "$expected" ]; then
        echo "source rules self-test: ok"
        exit 0
    fi
    echo "source rules self-test: mismatch"
    diff <(echo "$expected") <(echo "$actual") || true
    exit 1
fi

out=$(run)
if [ -n "$out" ]; then
    echo "$out"
    echo "source rules: $(wc -l <<< "$out" | tr -d ' ') violation(s)" >&2
    exit 1
fi
echo "source rules: ok"
