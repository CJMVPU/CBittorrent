# Native UI history

Historical behavior is recorded below; use [README.md](README.md) for the
current specification and [VALIDATION.md](VALIDATION.md) for dated checks.

## 0.7.0 — Connection diagnostics and UI clarity

- Add a task selection bar with direct file, Tracker and connection actions.
- Increase transfer row spacing, strengthen muted-text contrast and add checking
  and error filters. Highlight selected settings sections, align outlined inputs
  and wrap explanatory text.
- Add searchable live peer details with endpoints, client, progress, rates,
  transport, direction, encryption, sources and transfer/choking state.
- Show actual Tracker announce status and errors instead of configured-only URLs.
- Add per-task upload slots, TCP connect timeout and optional anonymous mode,
  retaining compatible defaults for existing profiles.

## 0.6.0 — Domain and adapter boundaries

- Route task operations, settings transactions and graceful shutdown through
  injectable application ports; serialize complete use cases across awaits.
- Separate domain policy, application orchestration, infrastructure and UI.
- Split the libtorrent adapter into command, session, configuration, query and
  support components while preserving the C ABI and saved profile format.
- Move runtime settings writes and download-directory creation off the UI thread.
- Persist partial batch successes, recover both settings stores after rejection,
  validate file priorities and stabilize equal-name task ordering.
- Render complete long filenames using a dedicated text layer and preserve
  animation phase across unchanged snapshots.
- Enforce dependency boundaries and exercise failure/shutdown paths in CI.

## 0.5.0 — State, UI and build refactoring

- Reconcile selection with visible tasks and fit all transfer columns inside the
  fixed window.
- Preserve task behavior when settings cannot be saved.
- Separate task summaries from requested file/Tracker details and update open
  detail pages without rebuilding navigation.
- Consolidate persistence scheduling and reduce repeated engine lookup work.
- Move filesystem browsing off the UI thread; reuse embedded list cells.
- Remove the unused floating inspector and separate embedded page components.
- Cache unchanged build inputs and verify a staged app before replacing output.
- Validate runtime library search paths and bundled minimum OS requirements.

## Expanded settings (0.2)

Settings stay inside the fixed main window, organized into seven sections:

- General: close-window background behavior and completion notifications.
- Downloads: default folder, add paused, sequential downloading and preallocation.
- Connection: listen port, UPnP/NAT-PMP, global and per-torrent connection limits.
- Speed: download/upload caps and global upload slots.
- BitTorrent: DHT/PeX/LSD, encryption, download/seed/total queue limits, seed ratio
  and cumulative active finished-time limits (including selected-file torrents).
- Tracker: a multiline default list, opt-in appending to new tasks, and an explicit
  action to append the saved list to existing tasks without replacing their trackers.
- Advanced: TCP/uTP selection and unauthenticated SOCKS5/HTTP proxy configuration
  with peer/Tracker routing choices.

Zero means automatic for the listen port and unlimited for rate/connection/slot
and seeding caps. Queue counts must be positive while stored. Preallocation
only affects newly added tasks; sequential downloading affects existing tasks
as well. Reaching either enabled seeding limit explicitly stops the task. Stop
state survives a restart. Manually stopped tasks remain stopped when changing
other settings. Proxy settings do not promise system-wide routing or anonymity.

Old settings files inherit defaults for new keys while retaining existing
preferences. Input is validated before application, and startup configures the
session before restoring torrents. Saving applies the configuration and writes
settings atomically; if writing fails, the prior runtime configuration is restored
or a rollback error is shown. Draft values persist across settings sections and
when switching back to transfers. Settings are saved only on explicit Save.

The shared font helper increases the prior typographic scale by one point,
including titlebar and statusbar text. Their heights remain 32pt and 27pt. App
and titlebar icons use the rounded white-background black CB monogram; see
`Design/README.md` for the source artwork and ICNS conversion command.


### Dock and menu bar (0.2.1)

Launch explicitly assigns the bundled CB monogram as the running Dock icon.
A persistent CB menu-bar item displays current transfer rates and task counts,
opens transfers or in-window settings, starts/pauses all tasks, and quits through
the normal resume-data save path. It remains available when the window is hidden.

Default Tracker URLs accept HTTP, HTTPS and UDP. Enter one URL per line; saving
trims blank lines and removes exact duplicates. Auto-append is off by default.
Saving a list does not change existing torrents; use **应用到现有任务** after
saving to append it explicitly. Existing tracker entries are preserved.


### Compact main window (0.3)

The single 32pt titlebar contains status filtering, search, Add, task actions and
transfer/settings navigation. There is no separate toolbar or floating inspector.
Task rows alternate white and light silver. The 27pt statusbar omits task and
selection/file counts and displays connected peers summed across all tasks,
alongside rates, session totals, DHT nodes and disk space. Settings still reuse
the same fixed 1000 × 680 window.

Dock and titlebar icons use a approved artistic interlocked CB mark on a white rounded
tile with transparent padding. The menu bar uses the same artwork as a template
image, so macOS supplies the light/dark foreground color without a white tile.


### Artwork consistency and compact rows (0.3.1)

The titlebar now shows only the app icon beside the window buttons. The task
row height is 27pt (previously 35pt), with white/silver bands extending through
unused table space, including the zero-task state. Dock, titlebar and menu bar
all use the approved calligraphic CB artwork; the geometric substitute has been
removed. Dock/titlebar retain the rounded white tile, while the menu bar uses
transparent artwork as an adaptive template.

### Underlined settings controls (0.3.2)

Settings use a common 300pt underline/input column for scalar values, paths and
choices. Standard text-field editor geometry is shared with the display state,
so focusing a value no longer applies a different inset. Numeric values remain
right-aligned. The redundant save reminder is removed; explicit Save remains.
The compact search cell positions the text and both icons explicitly. Window
buttons follow v2rayM's 16pt gray circles, revealing red/yellow actions on hover,
with reduced-motion support and unchanged close/minimize behavior.


### Compact single-window workflows (0.4)

The fixed window is now 900 × 600pt, with 24pt task rows. The titlebar and footer
remain 32pt and 27pt. The redundant top-right Transfers button is removed.
Settings navigation uses text-only selection color; the left-aligned Back to
Transfers button has a persistent background. Input columns are uniformly 260pt.

Adding tasks, browsing torrent files or directories, removal confirmation,
file priorities, Tracker lists, errors and About all render inside the existing
window. Returning from a nested picker restores the current settings draft or
add form. The save-location browser navigates folders and shows file metadata
without opening Finder. Removal keeps downloaded data unless explicitly selected.
System-owned permission prompts remain controlled by macOS.

The build compiles the approved artwork into a named AppIcon asset catalog and
packages Assets.car with an ICNS fallback, so system surfaces such as Stage
Manager can resolve the bundle icon independently of the running Dock icon.


### Button layout and installed icon identity (0.4.1)

Action buttons draw icon and title as a single measured group with a 6pt gap,
centered inside their background. Plain settings navigation remains left aligned.
The application no longer assigns `NSApplication.applicationIconImage` at runtime;
Dock and other system surfaces use the packaged AppIcon catalog and ICNS fallback.

Use the installed application in /Applications for normal launch/quit acceptance.
Keep older application backups as ZIP archives rather than loose .app bundles,
so Launch Services does not discover multiple obsolete copies with the same ID.
A local clean reinstall preserves the complete application support profile.

## 0.7.1 (13)

- Add persistent historical global share ratio to the footer with cumulative
  upload/download tooltip, independent of task removal and session resets.
- Import recoverable legacy resume totals once; preserve corrupt history for
  recovery instead of silently resetting it.
- Show remote peer interest alongside choking state to help inspect idle uploads.
