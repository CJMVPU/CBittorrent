#!/bin/bash
# Package the approved artistic mark and package all standard macOS ICNS sizes.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
iconset="${project_root}/build/icon/CBittorrent.iconset"
mkdir -p "${iconset}"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx27.0 \
    "${project_root}/native/App/BrandMark.swift" \
    "${project_root}/native/scripts/render_brand.swift" \
    -o "${project_root}/build/icon/render_brand"
"${project_root}/build/icon/render_brand" "${project_root}/native/Design/CB-app-icon.png" \
    "${project_root}/native/Resources/CB-symbol.png"
for size in 16 32 128 256 512; do
    sips -z "${size}" "${size}" "${project_root}/native/Design/CB-app-icon.png" \
        --out "${iconset}/icon_${size}x${size}.png" > /dev/null
    retina_size=$((size * 2))
    sips -z "${retina_size}" "${retina_size}" "${project_root}/native/Design/CB-app-icon.png" \
        --out "${iconset}/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "${iconset}" -o "${project_root}/native/Resources/CBittorrent.icns"
