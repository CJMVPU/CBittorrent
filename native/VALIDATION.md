# Native validation record

Validated locally on 2026-11-12 using the macOS 27.2 SDK, Apple Silicon and
libtorrent-rasterbar 2.1.2. This record describes the initial native client,
not the retained upstream Qt application.

## Build and dependency closure

- Release build: `./native/build.sh` passed.
- Default CMake route: configure and build in `build/cmake-check` passed.
- Final bundle: `build/native/CBittorrent.app`.
- Dependency audit: four arm64-only Mach-O files (CBittorrent,
  libtorrent-rasterbar 2.1.2, libssl 4 and libcrypto 4); no Qt; all non-system
  libraries bundled; executable minimum macOS version 27.0.
- `codesign --verify --deep --strict` and Info.plist validation passed.
- Bundled LXGWWenKaiMono-Medium font and OFL checked.
- `git diff --check` passed.

The bundle is signed ad hoc for local use. It has not been Developer ID signed
or notarized. At the user's request it was installed into
`/Applications/CBittorrent.app`; the installed bundle matched the build artifact,
passed the signature/dependency audit, and launched successfully with its normal
application profile. No installer or GitHub release was published.
The original validation predates the native CI migration. The current workflow
and local reproduction command are documented in `README.md`; remote acceptance
is recorded by the GitHub Actions run associated with each commit.

## Engine integration

`ctest --test-dir build/cmake-check --output-on-failure` passed 1/1 tests.
The engine test ran in 3.63 seconds. Its isolated loopback sessions verified:

- Hybrid magnet metadata acquisition and a 512 KiB payload, compared byte for byte.
- Stable task identity before metadata, after metadata and after restart.
- Explicit pause and file priority persistence; resume after restart.
- Duplicate and invalid magnet rejection.
- Removal preserving files and removal deleting files, both surviving restart.
- Session traffic totals remaining cumulative after task removal.

The runner is `native/tests/run.sh`. Tests create temporary data and do not
use an existing qBittorrent or CBittorrent profile.

## Native window inspection

The actual packaged app was launched with `CBT_ENGINE_LOCAL_ONLY=1` and a
separate profile under `build/native-ui-test/profile`. Native accessibility
inspection and screenshots confirmed:

- Compact custom title controls, combined toolbar and silver palette.
- Same-window settings and selection preserved when returning to transfers.
- Settings save feedback and the saved add-paused preference.
- Adding a test magnet produces a real engine task in the stopped state.
- Selection populates the floating inspector; it can be hidden.
- Bottom status displays task/file counts and both session traffic totals.
- Normal quit returns successfully; relaunch restores the stopped task.

Screenshots are local build artifacts at
`build/native-ui-test/main-window.png` and `settings-window.png`.
The fixed 1000 x 680 point window appears as 2000 x 1360 pixels on the Retina
capture. No real user downloads were added or removed during UI validation.

## Remaining acceptance

Public tracker/DHT behavior, external HTTPS tracker acceptance, Internet
throughput, notification delivery, file/URL association dispatch by Finder or
another browser, sleep/wake and long-running workloads remain unverified.
The UI test magnet was deliberately stopped; it was not a public-network
transfer test. See `MIGRATION.md` for features still awaiting migration.
