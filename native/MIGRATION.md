# qBittorrent to native CBittorrent

The default application is a new macOS-only Swift/AppKit client. Its torrent
engine is libtorrent, accessed through a small C ABI and Objective-C++ bridge.
It does not reuse qBittorrent's Qt-based session implementation as a hidden
backend. The upstream sources remain in this repository as reference material.

## Business behavior mapping

| Upstream reference | Native implementation | Current scope |
| --- | --- | --- |
| `src/base/bittorrent/sessionimpl.cpp` | `Engine/CBTEngine.mm` | Session creation, active download/seed queues, rate limits, alerts and cumulative session counters |
| `src/base/bittorrent/torrentimpl.cpp` | `Engine/CBTEngine.mm` | Add, explicit pause/resume, status, file priorities, remove and resume persistence |
| `src/gui/addnewtorrentdialog.cpp` | `App/AppStore.swift`, `App/UI/InWindowFlowView.swift` | In-window local torrent and magnet input, default destination, add-paused preference |
| `src/gui/transferlistmodel.cpp` and `transferlistwidget.cpp` | `App/Models.swift`, `App/UI/MainWindowController.swift`, `TransferTable.swift` | Fixed-width list, state filters, search, selection and live metrics |
| `src/gui/properties/propertieswidget.cpp` | `App/UI/MainWindowController.swift`, `App/UI/InWindowFlowView.swift` | In-window task action menu, files/priorities, configured Tracker list; floating inspector removed in 0.3 |
| `src/gui/optionsdialog.cpp` | `App/UI/SettingsView.swift` | Same-window download location, rate limits, close behavior and completion notifications |

This table records behavior reimplemented around libtorrent. It does not claim
line-for-line migration or full compatibility with upstream profile formats.
The retained source remains subject to its original license; the new client
continues under the repository's GPL-2.0-or-later license.

## Data boundary

The default profile is `~/Library/Application Support/CBittorrent`. Settings are
stored in `settings.json`, and per-task resume records in
`Session/ResumeData/*.fastresume`. The app holds an exclusive profile lock so
two instances cannot write the same session concurrently. `--profile PATH`
selects a separate profile for testing.

Task state is flushed after mutations, periodically by the engine and before
orderly exit. List polling requests summaries; open detail pages request only
the selected task’s files and trackers. Saves replace individual records atomically. A failed exit save
keeps the app running and reports the error. Removing a task preserves payload
files unless the user explicitly selects the delete-files option.

Existing qBittorrent profiles are not imported, converted or overwritten.
A future importer needs explicit compatibility checks and a preview of each
source task, save path and desired initial state.

## Remaining migration work

- Per-task limit overrides, scheduled alternative speeds and categories/tags.
- Rich peer and Tracker diagnostics, Tracker editing and authenticated proxies.
- RSS subscriptions, search plugins, Web UI and remote API.
- qBittorrent settings and task import.
- Developer ID signing, notarization and release updates.

The current validation covers isolated loopback transfer, metadata acquisition,
state persistence, core native UI interaction and the packaged dependency
closure. Public tracker, DHT, Internet throughput, sleep/wake and long-running
real-world torrent workloads need a separate acceptance pass.


## Settings coverage

The native client currently exposes 32 persisted settings fields.
Saved values take precedence; absent fields use AppSettings defaults.
This is not a complete migration of qBittorrent preferences.

| Missing UI category | Current behavior |
| --- | --- |
| Listen interface or IP selection | Fixed to all IPv4/IPv6 interfaces |
| Upload scheduling algorithm | Fixed slots |
| Polling and periodic save intervals | One-second AppStore summaries; engine-owned 30-second autosave |
| Unassigned disk I/O, buffer and connection-rate parameters | libtorrent defaults |
| Scheduled or alternative limits, per-task limits | Not implemented |
| Interface binding, IP filtering, proxy credentials | Not implemented |
| RSS, search plugins, Web UI, remote API, categories/tags | Not implemented |

Libtorrent defaults are not equivalent to qBittorrent defaults.
The latter explicitly configures additional engine parameters.
The imported local Tracker list is user data, not a source default.
