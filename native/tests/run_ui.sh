#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "${project_root}/build/native-tests"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx27.0 \
    "${project_root}"/native/App/Domain/*.swift \
    "${project_root}"/native/App/Application/*.swift \
    "${project_root}"/native/App/UI/*.swift \
    "${project_root}/native/tests/ui_test.swift" \
    -o "${project_root}/build/native-tests/ui_test"
"${project_root}/build/native-tests/ui_test"
