# CBittorrent

CBittorrent is a native BitTorrent client for **macOS 27 and newer on Apple
Silicon**. Its interface uses Swift and AppKit; a small Objective-C++ bridge
connects it directly to [libtorrent-rasterbar](https://libtorrent.org/).
The native app has **no Qt build or runtime dependency**.

This repository began as a fork of [qBittorrent](https://www.qbittorrent.org/).
Its original `src/`, `test/`, `dist/`, and legacy CMake modules remain available
as implementation references. They are not compiled into CBittorrent. The root
CMake entry point now builds only the native app; it does not discover Qt.
This is an independent early implementation, not a feature-complete port of
qBittorrent and not an official qBittorrent release.

## Build and run

On an Apple Silicon Mac with Xcode and the macOS 27+ SDK:

```sh
brew install libtorrent-rasterbar pkg-config
./native/build.sh
open build/native/CBittorrent.app
```

The script builds arm64 only, bundles non-system libraries, includes licenses,
signs the app ad hoc, and audits the entire bundle for Qt and external library
references. Build dependencies remain developer requirements; the resulting
app includes its libtorrent and OpenSSL libraries.

[Native implementation and validation](native/README.md) · [Migration map](native/MIGRATION.md) · [Installation](INSTALL)

## Interface direction

The silver titanium interface uses a fixed 900 × 600 window, compact custom
window controls, a single row for filters and task actions, fixed-width task
columns, and a bottom status bar. Settings and task workflows occupy the
same main window. The font is the bundled **LXGW WenKai Mono Medium**, licensed
under the [SIL Open Font License](native/Resources/Fonts/OFL.txt).

## Scope and data

The native app starts with the core torrent workflow: adding `.torrent` files
and magnet links, viewing task progress and transfer rates, pausing/resuming,
removing tasks, inspecting files and trackers, changing file priorities, viewing peer counts,
saving resume data, and setting
basic transfer limits. See the native documentation for current limitations.
Existing qBittorrent settings and torrent state are not automatically migrated;
CBittorrent keeps its own profile and does not overwrite the legacy profile.

## Attribution and license

qBittorrent's source and its original copyright notices are retained. Refer to
[COPYING](COPYING) for the repository's licensing terms and exceptions. New
native source is distributed under the same applicable project terms.
libtorrent, OpenSSL, Boost, and the bundled font have their own licenses; the
app build includes dependency license texts in `Contents/Resources/Licenses`
and the font's license alongside the font. CBittorrent is not associated with
or endorsed by those upstream projects.
