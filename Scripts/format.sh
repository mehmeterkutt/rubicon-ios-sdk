#!/usr/bin/env bash
# Formats every Swift file in place with the toolchain's swift format (D8). Run before every commit.
set -euo pipefail
cd "$(dirname "$0")/.."
swift format format --in-place --recursive --parallel Sources Tests ConsumerApps Package.swift
echo "format: done"
