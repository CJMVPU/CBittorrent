#!/bin/bash
# Shared by GitHub Actions and local release validation.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${project_root}"

check_environment() {
    if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
        echo "Native CI requires an Apple Silicon Mac without Rosetta." >&2
        return 1
    fi
    local os_version sdk_version
    os_version="$(sw_vers -productVersion)"
    sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
    if (( ${os_version%%.*} < 27 || ${sdk_version%%.*} < 27 )); then
        echo "Native CI requires both macOS 27+ and the macOS 27+ SDK." >&2
        return 1
    fi
    sw_vers
    uname -m
    xcodebuild -version
    xcrun --sdk macosx --show-sdk-version
    xcrun swiftc --version
}

verify() {
    local ci_build="${project_root}/build/ci"
    local artifact_dir="${ci_build}/artifacts"
    local app_path="${ci_build}/native/CBittorrent.app"
    local archive_path="${artifact_dir}/CBittorrent-macOS27-arm64.zip"
    local extracted
    mkdir -p "${artifact_dir}"
    check_environment | tee "${ci_build}/environment.txt"
    printf '%s  %s\n' \
        '7a674f448b15a1b3df781c3498973d77f71d270788f7f921080c1344e9d739e1' \
        'native/Resources/Fonts/LXGWWenKaiMono-Medium.ttf' | shasum -a 256 -c -
    cmake -S . -B "${ci_build}" -G Ninja \
        -DCBITTORRENT_CONFIGURATION=release -DBUILD_TESTING=ON
    cmake --build "${ci_build}" --parallel
    ctest --test-dir "${ci_build}" --output-on-failure
    python3 native/scripts/audit_no_qt.py "${app_path}"
    codesign --verify --deep --strict "${app_path}"
    plutil -lint "${app_path}/Contents/Info.plist"

    # A ZIP preserves the executable modes and app bundle through artifact upload.
    ditto -c -k --sequesterRsrc --keepParent "${app_path}" "${archive_path}"
    extracted="$(mktemp -d "${ci_build}/archive-check.XXXXXX")"
    ditto -x -k "${archive_path}" "${extracted}"
    diff -qr "${app_path}" "${extracted}/CBittorrent.app"
    codesign --verify --deep --strict "${extracted}/CBittorrent.app"
    python3 native/scripts/audit_no_qt.py "${extracted}/CBittorrent.app"
    rm -rf "${extracted}"
    cp "${app_path}/Contents/Resources/build-info.json" "${artifact_dir}/build-info.json"
    cp "${ci_build}/environment.txt" "${artifact_dir}/environment.txt"
    (cd "${artifact_dir}" && shasum -a 256 CBittorrent-macOS27-arm64.zip > SHA256SUMS)
    echo 'PASS: native build, loopback tests, Qt-free audit, signing and ZIP round-trip.'
}

case "${1:-verify}" in
    environment) check_environment ;;
    verify)
        mkdir -p build/ci
        verify 2>&1 | tee build/ci/verification.log
        ;;
    *) echo "Usage: $0 [environment|verify]" >&2; exit 2 ;;
esac
