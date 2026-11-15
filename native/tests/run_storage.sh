#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "${project_root}/build/native-tests"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx27.0 \
    "${project_root}"/native/App/Domain/*.swift \
    "${project_root}/native/App/Application/Ports.swift" \
    "${project_root}/native/App/Infrastructure/ProfileRepository.swift" \
    "${project_root}/native/tests/storage_test.swift" \
    -o "${project_root}/build/native-tests/storage_test"
"${project_root}/build/native-tests/storage_test"
