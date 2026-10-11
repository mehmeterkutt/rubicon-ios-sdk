#!/usr/bin/env bash
# Generates the three consumer apps with XcodeGen (D10) and builds them for the simulator
# (iOS Public API 3): Swift 5 mode, Swift 6 mode with warnings as errors, Objective-C.
# Usage: build-consumer-apps.sh [--test]   --test also runs their UI tests (step 8.1).
set -euo pipefail

cd "$(dirname "$0")/.."
command -v xcodegen > /dev/null || { echo "consumer apps: xcodegen is not installed (brew install xcodegen)" >&2; exit 1; }
for app in Swift5App Swift6App ObjCApp; do
    (cd "ConsumerApps/$app" && xcodegen generate --quiet)
    action=build
    [ "${1:-}" = "--test" ] && action=test
    xcodebuild "$action" -project "ConsumerApps/$app/$app.xcodeproj" -scheme "$app" \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/consumer \
        CODE_SIGNING_ALLOWED=NO -quiet
    echo "consumer apps: $app $action ok"
done
