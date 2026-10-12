#!/usr/bin/env bash
# Generates the three consumer apps with XcodeGen (D10) and builds them for the simulator
# (iOS Public API 3): Swift 5 mode, Swift 6 mode with warnings as errors, Objective-C.
# Usage: build-consumer-apps.sh [--test] [ios-major]
#   --test  also runs each app's UI tests (the scenarios of step 8.1) on the newest available
#           iPhone simulator, or on the newest runtime of the given major version.
set -euo pipefail

cd "$(dirname "$0")/.."
command -v xcodegen > /dev/null || { echo "consumer apps: xcodegen is not installed (brew install xcodegen)" >&2; exit 1; }
action=build
if [ "${1:-}" = "--test" ]; then
    action=test
    shift
fi
if [ "$action" = test ]; then
    udid=$(xcrun simctl list devices available -j | python3 Scripts/lib/pick-simulator.py "${1:-}")
    destination="id=$udid"
else
    destination="generic/platform=iOS Simulator"
fi
for app in Swift5App Swift6App ObjCApp; do
    (cd "ConsumerApps/$app" && xcodegen generate --quiet)
    # Without `-collect-test-diagnostics never` a failing test makes xcodebuild run `simctl diagnose`
    # for up to ten minutes before it reports (plan section 15, step 7.2).
    xcodebuild "$action" -project "ConsumerApps/$app/$app.xcodeproj" -scheme "$app" \
        -destination "$destination" -derivedDataPath .build/consumer \
        -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO -quiet
    echo "consumer apps: $app $action ok"
done
