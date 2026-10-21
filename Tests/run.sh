#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output="$(mktemp /tmp/simble-isolation-tests.XXXXXX)"
trap 'rm -f "$output"' EXIT
xcrun --sdk macosx swiftc -swift-version 5 -o "$output" App/PeripheralIsolation.swift Tests/PeripheralIsolationTests.swift
"$output"
