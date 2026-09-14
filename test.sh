#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cp Tests/DriftMathTests.swift "$TMP/main.swift"
xcrun swiftc -O Sources/DriftMath.swift "$TMP/main.swift" -o "$TMP/t"
"$TMP/t"
