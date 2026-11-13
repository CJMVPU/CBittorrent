# CBittorrent

A native BitTorrent client for **macOS 27+ on Apple Silicon**.
Built with Swift, AppKit and libtorrent. No Qt dependency.

## Features

- Fixed 900 × 600 window with compact, alternating task rows.
- Search, filters, settings and task actions in one window.
- Torrent and magnet input, pause/resume and file priorities.
- Tracker settings, connection limits and saved task state.
- Artistic CB app icon and a macOS menu bar item.
- Bundled LXGW WenKai Mono Medium font.

## Build

Requires an Apple Silicon Mac, Xcode and the macOS 27+ SDK.

```sh
brew install libtorrent-rasterbar pkg-config
./native/build.sh
open build/native/CBittorrent.app
```

The build bundles dependencies and signs the app ad hoc.
See [native documentation](native/README.md) for details and validation.

## Workflow

Keep two branches: `master` and `codex`.
Develop, commit and push on `codex`.
After checks pass, merge into `master` and push.
Return to `codex` for the next change; reuse it instead of adding branches.

## Scope and license

This independent project began as a [qBittorrent] fork.
Upstream code remains as reference and is not part of the native build.
Feature coverage is incomplete; see the [migration map].
CBittorrent stores its own profile and leaves qBittorrent data unchanged.

Source is licensed under [GPL-2.0-or-later][license].
Dependency licenses are included in the app bundle.
The bundled font uses the [SIL Open Font License][font-license].
This project is not an official qBittorrent release.

[qBittorrent]: https://www.qbittorrent.org/
[migration map]: native/MIGRATION.md
[license]: COPYING
[font-license]: native/Resources/Fonts/OFL.txt
