#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "${project_root}/build/native-tests"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx27.0 \
    "${project_root}/native/App/Models.swift" \
    "${project_root}/native/App/AppSettings.swift" \
    "${project_root}/native/tests/settings_test.swift" \
    -o "${project_root}/build/native-tests/settings_test"
"${project_root}/build/native-tests/settings_test"
