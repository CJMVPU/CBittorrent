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


## Version 0.2 settings and icon acceptance

The expanded settings build passed the shared `native/scripts/ci.sh verify`
route locally. CTest passed 2/2 suites: the libtorrent integration suite and the
Swift settings migration/validation suite. No remote CI run is claimed for
these uncommitted changes.

The engine tests exercise effective settings readback, invalid settings without
partial application, configured startup, task flags, manual-pause preservation,
preallocation and ratio/time stopping with persistence. The Swift test verifies
older six-key settings load safely, new defaults, normalization, full JSON
round-trip and invalid input rejection.

An isolated preview application and profile were used for native UI testing:
editable controls, cross-category drafts, invalid port rejection, successful
speed/port/proxy saves and safe disabling of queue settings after invalid input.
Saved JSON was read back to confirm the exact values. Inspection found and fixed
a custom-cell editability regression before delivery. Proxy testing was limited
to configuration/readback; no external authenticated or unauthenticated proxy
endpoint is claimed to have been tested.

The generated black CB artwork on white is packaged as ICNS and declared in
Info.plist. The titlebar and statusbar remain 32pt and 27pt high while the shared
font scale increases by one point. The final bundle passed signing and the
arm64/macOS27/Qt-free/icon/font audit, including the ZIP extraction round-trip.
Version 0.2.0 build 2 was installed into `/Applications/CBittorrent.app`, verified
against the final build and launched successfully. The old application is kept
under `build/install-backups/CBittorrent-0.1.0.app`; no existing task/profile data
was removed or replaced by the isolated UI test profile.

## 0.2.1 — Dock, menu bar and Tracker settings (2026-11-12)

- `native/scripts/ci.sh verify`: PASS; 2/2 CTest tests, arm64/macOS 27 and
  Qt-free dependency audit, ICNS/font resources, signature and ZIP round trip.
- Tracker tests cover old settings migration, normalization and invalid URL
  rejection in Swift and the engine, enabled/disabled automatic appending for
  torrent files and magnets, preserving original trackers, explicit application
  counts and duplicate suppression, and persistence after restart. Saving
  defaults and restoring existing tasks do not retroactively append trackers.
- Native UI checked with an isolated profile and loopback Tracker URLs: multiline
  paste, auto-add switch, save normalization and button enablement. The installed
  app's Tracker page was confirmed via accessibility with empty defaults.
- Installed `/Applications/CBittorrent.app` version 0.2.1 (3), preserving the user
  profile, retaining a 0.2.0 bundle backup under build/install-backups, and
  refreshing this bundle's LaunchServices registration. Runtime now explicitly
  assigns the bundled monogram to NSApp.applicationIconImage.
- A retained NSStatusItem provides CB branding, rates/counts and window/settings,
  all-task start/pause and normal graceful quit actions. System Dock and menu-bar
  automation timed out, so their actual rendered appearance and menu interaction
  were not visually confirmed in this run. No public Tracker connectivity claim.
- This verification is local; the uncommitted changes have not run on remote CI.

## 0.3.0 — Single-row chrome and connected brand (2026-11-12)

- `native/scripts/ci.sh verify`: PASS, including both CTest suites, Qt-free
  arm64/macOS 27 audit, signing, resources and ZIP round trip.
- Native AppKit UI checked using eight paused synthetic torrents in an isolated
  loopback-only profile. The status dropdown changed to downloading (empty), then
  stopped (eight); searching for 设计 returned one task. Selecting a row enabled
  task actions, with no inspector or selection/file counts in the statusbar.
- Final UI capture: `build/compact-preview/main-window-0.3.0.png`. It shows the
  single 32pt titlebar, alternate actual-task row backgrounds, full-width list
  and connected-peer status. Empty area remains unstriped. Main/settings remain
  in the same fixed 1000 × 680 window with a 27pt footer.
- `native/scripts/make_icon.sh` and shellcheck passed. All ten generated iconset
  PNG representations were inspected programmatically: all four corners have
  zero alpha and the tile interior is opaque. The Dock resource now uses the
  native connected vector brand on a rounded white tile; the menu-bar item uses
  the same vector as a template image with no text title.
- Installed 0.3.0 (4) at `/Applications/CBittorrent.app`, preserved user profile,
  retained the previous bundle at `build/install-backups/CBittorrent-0.2.1.app`,
  refreshed LaunchServices and verified the installed signature. The installed
  main window's new controls were confirmed via accessibility. Dock/menu-bar
  rendering was not directly captured; icon alpha and bundled resources were
  checked independently. The temporary preview app was quit.
- Changes remain local and uncommitted; no remote CI result is claimed.

## 0.3.1 — Restore approved artwork and empty-row bands (2026-11-12)

- Restored the original calligraphic CB design using a background-only imagegen
  extraction in `Resources/CB-symbol.png`. Dock/titlebar packaging and the
  menu-bar template both consume this artwork; the geometric substitute is gone.
- Row height reduced from 35pt to 27pt. An NSTableView background override extends
  matching white/silver row bands through all unused space. The titlebar displays
  only the app icon, and the recovered space expands the search field.
- CUA screenshots verified the empty state and eight paused synthetic task rows:
  `build/compact-preview/empty-window-0.3.1.png` and
  `build/compact-preview/main-window-0.3.1.png`. Text/progress remain within rows,
  selection highlighting works, and both task/empty backgrounds align.
- `native/scripts/ci.sh verify` passed both CTest suites, signing, no-Qt/arm64
  dependency and resource audits, and ZIP round trip. All ten icon source sizes
  passed corner-alpha and opaque-tile checks. Shellcheck and diff checks passed.
- Installed 0.3.1 (5), preserved user profile, backed up 0.3.0 under build, and
  refreshed LaunchServices. Installed ICNS and shared menu-art PNG hashes match
  the validated sources. Installed main-window controls confirmed via CUA;
  Dock/menu-bar surfaces were not separately captured. The preview app is closed.
- This is local verification; changes remain uncommitted and unpushed.

## 0.3.2 — Stable underline inputs, search and window controls (2026-11-12)

- Removed custom SettingsInputCell drawing offsets. Standard NSTextField display
  and field-editor layout share the same 300pt underline container. Labels,
  fields, units and dropdowns use common column geometry. Removed save reminder.
- Reused the native round-button appearance/animation from the live v2rayM
  WindowControlButtons.swift source without modifying that project or app.
- Native UI verified unfocused/focused input positions, editing 200 to 240 in an
  isolated profile, Save success, and persistence after preview relaunch.
  Final screenshot: `build/compact-preview/settings-0.3.2.png`.
- Full local CI verification passed both test suites, no-Qt/resource audits,
  signing and archive round trip. A subsequent search-text vertical adjustment
  was rebuilt, signed/audited and visually checked in the final preview.
- Read qBittorrent's existing AdditionalTrackers list and enable flag locally.
  Imported 74 distinct URLs in order into the installed CBittorrent profile,
  preserving other settings; qBittorrent files were read-only. Model validation
  and atomic-write readback passed. The installed Tracker page independently
  showed 74 URLs with automatic appending enabled. No URLs enter source control.
- Installed 0.3.2 (6), preserved user data, retained prior app under build backups,
  and verified installed signature. Preview was closed; installed app remains
  open on Tracker settings. Changes remain local/uncommitted; no remote CI claim.

## 0.4.0 — Smaller window and inline workflows (2026-11-13)

- Full `native/scripts/ci.sh verify` passed: release build, native_engine and
  native_settings CTest suites, arm64/macOS 27/no-Qt audit, asset-catalog audit,
  signing and ZIP round trip. Log: `build/ci-0.4.0.log`.
- CUA verified a fixed 900 × 600pt window with 24pt task rows, 32pt titlebar and
  27pt footer. Settings Back to Transfers is left aligned with a filled surface;
  selected settings menus change foreground only. Top-right Transfers is gone.
  Capture: `build/compact-preview/settings-0.4.0.png`.
- An isolated loopback-only profile verified in-window torrent browsing and
  path insertion, empty-input and duplicate-torrent errors, adding a paused
  synthetic magnet, and removing it while retaining payload files. Eight fixture
  tasks remain. No actual user tasks were added or removed.
- In-window file-priority saving, Tracker display and save-location browsing
  were exercised. Directory selection returned to the existing settings page
  with its unsaved preallocation change intact; that test change was restored.
  About 0.4.0 was verified in the installed main window. Source audit found no
  application alert, sheet, system file-picker or external Finder-open call.
  macOS-owned notification permission prompts remain outside application control.
- Compiled the approved artwork into a named AppIcon/Assets.car with ICNS
  fallback. Installed version 0.4.0 (7), backed up 0.3.2 under build/install-backups,
  refreshed only this bundle's LaunchServices registration, and verified its
  signature and resource/dependency audit. User settings were byte-identical
  across installation: 74 Tracker URLs and auto-append enabled.
- NSWorkspace system bundle-icon lookup returned the approved artistic CB
  image (32 representations), inspected at `build/icon/system-icon-0.4.0.png`.
  The Stage Manager thumbnail badge itself was not captured by the available
  app-window screenshot tool; its actual compositor rendering remains unverified.
- Preview was closed. Installed application remains open on General settings.
  Changes remain local/uncommitted/unpushed; no remote CI result is claimed.


## 0.4.1 — Centered buttons and clean installation (2026-11-13)

- Full local CI passed: release compilation, both CTest suites, packaged icon and
  no-Qt/arm64 audits, code signing and ZIP round trip. `build/ci-0.4.1.log`.
- Removed all runtime applicationIconImage assignment. A shared NSButtonCell
  lays out a compact centered icon/title group with a 6pt gap; plain settings
  navigation retains left alignment. Normal Finder launch produced full-size
  screenshots verifying Settings and Add controls:
  `build/identity-audit/settings-0.4.1.png` and `add-0.4.1.png`.
- On the user's explicit clean-reinstall request, archived and unregistered 14
  installed/build/preview/backup bundles, removed only the CBittorrent recent
  Dock item (one entry), and restarted Dock. Other Dock entries/settings were
  retained. Every user-profile file hash matched before/after reinstall.
- Installed 0.4.1 (8) at /Applications/CBittorrent.app. The final Launch Services
  audit contains exactly one CBittorrent app registration at that path. The
  duplicate release build bundle was removed after matching installation; its
  verified ZIP remains in build/ci/artifacts. Old app ZIPs are under
  build/identity-audit/archived-apps; downloaded files and profiles were retained.
- Normal Finder launch, quit and relaunch passed. After quit, pgrep and
  NSWorkspace found no CBittorrent process or associated running entry; Dock had
  one legitimate recent-app item pointing to the installed path, no pinned
  CBittorrent item. The system-resolved icon after exit was inspected and is the
  artistic CB, independent of any running app override.
- After the clean reinstall, the user explicitly confirmed that Stage Manager
  displays the correct artistic CB badge. This completes visual acceptance of
  that system-owned surface in addition to the resource/registration checks.
- Installed application remains on General settings. These are local build and
  installation results; remote CI status must be checked separately after push.
