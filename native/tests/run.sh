#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_build="${project_root}/build/native-tests"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
if (( ${sdk_version%%.*} < 27 )); then
    echo "The native engine test requires the macOS 27 SDK or later." >&2
    exit 1
fi

libtorrent_prefix="$(brew --prefix libtorrent-rasterbar)"
boost_prefix="$(brew --prefix boost)"
export PKG_CONFIG_PATH="${libtorrent_prefix}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
read -r -a torrent_cflags <<< "$(pkg-config --cflags libtorrent-rasterbar openssl)"
read -r -a torrent_libraries <<< "$(pkg-config --libs libtorrent-rasterbar)"
compiler="$(xcrun --find clang++)"
common_flags=(-std=c++20 -arch arm64 -mmacosx-version-min=27.0 -isysroot "${sdk_path}"
    -I"${boost_prefix}/include" -I"${project_root}/native/Engine")

mkdir -p "${test_build}"
"${compiler}" "${common_flags[@]}" "${torrent_cflags[@]}" -fobjc-arc \
    -c "${project_root}/native/Engine/CBTEngine.mm" -o "${test_build}/CBTEngine.o"
"${compiler}" "${common_flags[@]}" "${torrent_cflags[@]}" \
    "${project_root}/native/tests/engine_smoke.cpp" "${test_build}/CBTEngine.o" \
    "${torrent_libraries[@]}" -framework Foundation -o "${test_build}/engine_smoke"

# The executable creates its own /tmp fixture and binds both sessions to loopback.
# No installed app, user profile, public tracker, or public DHT is used.
"${test_build}/engine_smoke"
