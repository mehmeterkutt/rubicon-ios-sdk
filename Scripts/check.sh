#!/usr/bin/env bash
# Everything CI runs, in order (plan section 6). The pull request lane runs the default set; the
# simulator lane adds --all (simulator suite, consumer apps, DocC build).
#   check.sh          format lint, build (macOS and simulator), tests with coverage, source rules,
#                     required-reason grep, API record, docs
#   check.sh --all    the above plus test-simulator.sh, build-consumer-apps.sh, check-docs.sh --build
set -euo pipefail

cd "$(dirname "$0")/.."
step() { printf '\n==> %s\n' "$*"; }

step "format lint"
swift format lint --strict --recursive --parallel Sources Tests ConsumerApps Package.swift

step "build (macOS)"
swift build

step "build (iOS simulator, deployment target floor)"
swift build --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --triple arm64-apple-ios15.0-simulator

step "tests with coverage (macOS)"
Scripts/check-coverage.sh

step "source rules"
Scripts/check-source-rules.sh --self-test
Scripts/check-source-rules.sh

step "required-reason APIs"
Scripts/check-required-reason-apis.sh --self-test
Scripts/check-required-reason-apis.sh

step "golden files"
Scripts/refresh-golden.sh --check

step "public API record"
Scripts/api-diff.sh

step "documentation"
Scripts/check-docs.sh

if [ "${1:-}" = "--all" ]; then
    step "simulator suite"
    Scripts/test-simulator.sh
    step "consumer apps"
    Scripts/build-consumer-apps.sh
    step "DocC build"
    Scripts/check-docs.sh --build
fi

printf '\ncheck: ok\n'
