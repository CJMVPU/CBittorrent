#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "${project_root}/build/native-tests"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx27.0 \
    "${project_root}"/native/App/Domain/*.swift \
    "${project_root}/native/App/UI/TransferSelection.swift" \
    "${project_root}/native/App/Application/SettingsTransaction.swift" \
    "${project_root}/native/App/UI/Theme.swift" \
    "${project_root}/native/App/UI/TransferTable.swift" \
    "${project_root}/native/App/UI/TransferTableLayout.swift" \
    "${project_root}/native/App/UI/FlowListView.swift" \
    "${project_root}/native/App/UI/FileSystemService.swift" \
    "${project_root}/native/tests/ui_test.swift" \
    -o "${project_root}/build/native-tests/ui_test"
"${project_root}/build/native-tests/ui_test"
