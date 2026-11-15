#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "${project_root}/build/native-tests"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx27.0 -typecheck \
    "${project_root}"/native/App/Domain/*.swift
# No AppKit, C bridging header or libtorrent: the inner layers stand alone.
xcrun swiftc -swift-version 5 -target arm64-apple-macosx27.0 \
    "${project_root}"/native/App/Domain/*.swift \
    "${project_root}"/native/App/Application/*.swift \
    "${project_root}/native/tests/application_test.swift" \
    -o "${project_root}/build/native-tests/application_test"
"${project_root}/build/native-tests/application_test"
