# Native CBittorrent

This target is an independent Swift/AppKit application using libtorrent
through a C interface implemented in Objective-C++. No Qt library, qBittorrent
executable, WebView UI, or upstream Qt source is used by this target.

## Requirements

- Apple Silicon Mac running macOS 27 or newer; no Intel or Rosetta build.
- Xcode providing the macOS 27+ SDK and Swift compiler, selected with
  `xcode-select`.
- Python 3.9 or newer (`/usr/bin/python3` is used by the build wrapper).
- `pkg-config` and libtorrent-rasterbar >= 2.1 and < 3; Homebrew supplies the engine,
  Boost headers and OpenSSL libraries.

```sh
brew install libtorrent-rasterbar pkg-config
./native/build.sh
open build/native/CBittorrent.app
```

For a debug build, use `./native/build.sh --configuration debug`. A custom
output folder can be selected with `--output /absolute/path`. Only that
folder's `CBittorrent.app` is replaced on rebuild. The build does not install
into `/Applications` or change Homebrew libraries.

The optional root CMake target runs the same script:

```sh
cmake -S . -B build -G Ninja
cmake --build build
```

Use `-DCBITTORRENT_CONFIGURATION=debug` at configure time for debug builds.
The old Qt-related CMake options are not part of this build.

## Architecture and packaging

- `App/`: Swift state, engine service and app lifecycle.
- `App/UI/`: native AppKit interface and fixed main window.
- `Engine/CBTEngine.h`: ownership-explicit C API imported into Swift.
- `Engine/CBTEngine.mm`: libtorrent session, commands, snapshots and resume data.
- `Resources/Fonts/`: unmodified LXGW WenKai Mono Medium 1.522 and its OFL.
- `scripts/build_native.py`: compilation, dylib relocation, notices, signing.
- `scripts/audit_no_qt.py`: independent Mach-O dependency audit.

The executable and every copied library are arm64. The app requires macOS
27.0. Non-system libraries are copied into `Contents/Frameworks`; load commands
in those copies are rewritten to bundle-relative paths. The build records
library versions and original source checksums in `Resources/build-info.json`.
The runtime does not require Homebrew or Qt. The font is registered for the
app's process and is not installed into the user's Fonts folder.

The build signs the app ad hoc and verifies its signature. Developer ID
signing, notarization, App Store sandboxing and a distributable installer are
not provided by this local build route.

## Scope

The initial native implementation covers the essential torrent flow: adding
local torrent files or magnet links, selection and status updates, pause and
resume, removal, file lists and priorities, tracker lists and peer counts,
transfer limits and persisted resume
data. The application registers the `.torrent` type and `magnet:` URL scheme.
Settings reuse the main window. The fixed 1000 × 680 window cannot be resized,
maximized or made full screen.

This is not full qBittorrent feature parity. RSS, search plugins, the Web UI,
remote control, automatic import of qBittorrent's profile, advanced queue and
ratio rules, IP filtering, proxy configuration and per-tracker editing have
not been migrated. Retained upstream code is a reference for subsequent work,
not evidence that those features exist in the native app. See the
[migration map](MIGRATION.md) for the qBittorrent-to-native responsibility mapping.

CBittorrent uses a separate application support profile. Existing qBittorrent
settings, resume data and torrent files are not overwritten. Removing a task
must be distinguished from deleting its downloaded data in the UI; do not use
real user data for destructive tests.

## Verification

Every successful build runs these checks automatically; they can be repeated:

```sh
python3 native/scripts/audit_no_qt.py build/native/CBittorrent.app
codesign --verify --deep --strict build/native/CBittorrent.app
plutil -lint build/native/CBittorrent.app/Contents/Info.plist
```

The audit visits every Mach-O file, requires arm64-only slices, rejects Qt and
external library references, checks bundled dependency resolution, and verifies
the plist and executable deployment targets and font/license resources. It does not prove live
Internet transfer performance or interoperability with every tracker.

The engine integration test uses isolated temporary profiles and loopback-only
peers, with DHT, trackers, local discovery and router traffic disabled:

```sh
./native/tests/run.sh
# Or, after CMake configuration:
ctest --test-dir build --output-on-failure
```

It creates a 512 KiB payload and a hybrid torrent, downloads metadata and bytes
through a v1 magnet, verifies exact content, tests stable IDs, pause/resume,
file-priority persistence, duplicate and invalid-magnet rejection, both removal
that preserves files and explicit deletion of test data, restart restoration,
and cumulative session counters after task removal.
It does not access existing user profiles or downloads.

Manual acceptance should additionally cover external `.torrent` and magnet
opening and visual inspection of the compact window, floating inspector and
in-window settings. Real public tracker and Internet transfer checks remain
separate from these local checks.

## GitHub Actions

`Native macOS CI` runs on pushes to `master` and `codex/**`, pull requests into
`master`, and manual dispatch. It uses GitHub's `xcode-27` arm64 runner, which
runs macOS 27; the environment step rejects older OS/SDK versions and Intel.
The runner label is documented in the
[GitHub runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
and the [image inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).

The workflow installs only native build dependencies and validation tools,
checks workflows and shell/Python syntax, builds the Release bundle, runs CTest,
and verifies arm64 architecture, deployment target, dependency closure, font
integrity and ad-hoc signing. It then creates a ZIP, extracts it and repeats
signature/dependency checks to verify the archived app.

Successful runs upload `CBittorrent-macOS27-arm64-<commit>` containing the app
ZIP, SHA-256 checksum, dependency provenance and toolchain details. Diagnostics
are uploaded even when a build/test fails. These are ad-hoc-signed CI builds,
not notarized releases. No installation or user profile modification occurs.
All third-party actions are pinned to commit SHAs; the token is read-only and
checkout credentials are not persisted. Older runs for the same branch/PR are
cancelled when superseded.

Run the same build/test/package sequence locally with:

```sh
native/scripts/ci.sh verify
```

The old Qt/Linux/Windows build matrices, Web UI/search-plugin checks, legacy
file-health workflow and upstream stale-PR bot were retired. Their definitions
remain in Git history. Native workflow and source validation now live in the
single macOS workflow, alongside the actual application build and engine test.
Fork owners must enable Actions once before the first run.
