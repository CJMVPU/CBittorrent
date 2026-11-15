# Native application architecture

The native executable uses domain-oriented layers and application-owned ports.
It remains one Swift executable and one C bridge, without a dependency injection
framework or a new runtime dependency. The retained qBittorrent tree is not part
of this executable and is not reorganized by this refactor.

## Ownership and dependency direction

| Area | Owns | Must not own |
| --- | --- | --- |
| `App/Domain` | Transfer state classification, priority invariants, completion transitions, settings validation and transfer read models | AppKit, engine handles, persistence operations |
| `App/Application` | Transfer use cases, settings transactions, ordering, shutdown, outbound port definitions | C ABI calls, concrete storage, macOS notification APIs |
| `App/Infrastructure` | Serial C bridge adapter, JSON settings repository, local directory creation, system notifications | Window state or user interaction |
| `App/UI` | AppKit views, selection, filtering, presentation callbacks, file browsing | Engine construction or settings transactions |
| `App/Composition` | Construction and wiring of production adapters | Business rules |
| `Engine` | libtorrent session, torrent handles, resume-data persistence and C ABI | AppKit presentation |

The dependency direction is UI to Application to Domain. Infrastructure
implements application ports; Composition knows the concrete implementations.
The entry point retains process locking, OS open events and application lifetime.
Runtime settings writes and download-directory preparation run off the main
thread; use-case serialization still waits for them to finish before continuing.
The filesystem browser remains a presentation utility with asynchronous I/O;
it is independent of transfer and settings use cases.

Transfers and client preferences are the current domain areas. A libtorrent
session remains the authority for mutable transfer state and resume data.
Swift snapshots are read models, not competing mutable torrent aggregates.
Do not copy the engine's state machine into Swift or add a second torrent
repository simply to satisfy an architectural pattern.

`Codable` on the read models and preferences deliberately preserves the current
JSON contract and settings migration behavior. The C adapter is the boundary
for interpreting engine responses. If a future engine version changes its wire
schema, introduce versioned DTO mapping in that adapter; do not expose its new
schema to views. Unknown engine states remain in All rather than being assigned
a misleading known state. Existing profile filenames and resume formats remain
unchanged.

## Use-case consistency

`TransferApplication` serializes whole use cases, including asynchronous engine
calls and persistence. MainActor isolation alone does not provide this property:
a second task can enter while the first task awaits the engine. The private task
tail preserves accepted operation order. Read operations also pass through this
boundary to avoid observing a partially applied settings transaction.

A batch is intentionally not atomic: earlier accepted torrents cannot safely be
undone by deleting them. Addition reports accepted sources and the failure.
Other commands stop at the first failed item, flush earlier mutations and report
both operation and persistence failures when necessary. UI refreshes reconcile
the actual engine state. File deletion continues to require the explicit command
flag supplied by the confirmation flow.

Settings are validated, then persisted atomically before applying live policy.
An engine rejection triggers restoration of both disk and live settings. Both
restorations are attempted even if one fails. Failed restoration is reported;
this is a compensating transaction, not an atomic transaction across disk and
libtorrent. The in-memory committed settings advance only after success.

Shutdown rejects new work, drains accepted work including its persistence, then
asks the adapter to save and release the session. A save failure keeps the engine
available and reopens application operations so the user can retry. Cancellation
of a UI polling task does not discard accepted mutations.

Completion detection consumes snapshots once per application refresh and emits
only transitions from incomplete to complete. The initial snapshot is a baseline.
Notification delivery and authorization use an injectable port. Aggregate counts
and peer totals are computed in one pass. Transfer sorting breaks equal-name ties
by stable ID so refreshes do not shuffle equal-name rows.

## Engine adapter components

The C ABI is unchanged. Its implementation is separated into independently
compiled responsibilities so library updates do not require editing one large
session-and-UI-contract file:

- `CBTEngine.mm`: C command facade, locking, ownership and exception translation.
- `EngineSession.h` / `.mm`: internal session aggregate, identities, task policy,
  alert processing and resume-save lifecycle. Definitions stay out of the header.
- `EngineConfiguration.h` / `.mm`: input validation and libtorrent settings mapping.
- `EngineQueries.mm`: summary, detail and effective-settings JSON projections.
- `EngineSupport.h` / `.mm`: C string ownership, identity/state mapping and atomic
  resume-file writes.

Internal headers are not imported into Swift. Both production and integration
builds compile all adapter translation units; C ABI ownership and the existing
loopback regression suite remain the compatibility gates.

## Extending features

1. Define business values and invariants in Domain. Add only concepts required by
   the feature; do not create generic repositories or event buses preemptively.
2. Add an Application use case. Define a narrow outbound port when the capability
   needs storage, an engine operation or an external service.
3. Implement the port in Infrastructure or extend the existing engine adapter.
   Keep pointer ownership, JSON decoding and library-specific behavior there.
4. Wire the implementation in Composition and expose the use case through the
   UI store. Views should not construct adapters.
5. Test policy without the engine, failure paths with fakes, then actual C bridge
   behavior using isolated loopback profiles.

RSS, search and remote control are future contexts, not implemented features.
When introduced, give each its own application API and adapters rather than
expanding the UI store or treating every feature as a transfer-engine method.

## Updating upstream

There are two separate upstream concerns. The retained qBittorrent source is a
reference for feature behavior; libtorrent is the native runtime dependency.
A qBittorrent source merge does not automatically implement native features.

For each update, record the source revision/version and affected behavior in a
review note. Compare it with `MIGRATION.md`. Keep reference-tree changes separate
from native behavior changes so subsequent upstream merges retain recognizable
paths. Review C ABI ownership and error semantics before changing the adapter.
For libtorrent updates, also verify settings mapping, state classification,
resume compatibility, deployment target and bundled dependency closure.

Develop on the existing `codex` branch. Fetch and synchronize with `master`
without discarding local work. Run `native/scripts/ci.sh verify`; review the
native diff and retained upstream diff separately. Push `codex`. Integrate into
`master` only when requested, preferably by fast-forward, then return to `codex`.
Do not create upstream issues or PRs automatically.

This structure limits where upstream integration affects the native app; it
cannot eliminate semantic conflicts or guarantee compatibility with an untested
future upstream release.

## Enforcement and tests

`run_application.sh` type-checks Domain independently and compiles Domain plus
Application with test doubles and no C bridge, AppKit or libtorrent. It tests
partial failures, settings rollback, completion transitions, shutdown ordering
and failed-shutdown retry. `architecture_test.py` guards imports, C bridge access
and UI-store dependencies. Both are registered in CTest and the existing CI path.
These are logical layers with dependency checks, not separate Swift packages.

The existing engine integration, settings, UI and packaging tests remain required.
Release build and signature/dependency audits verify the production composition.
Public tracker performance and manual OS/UI acceptance remain separate checks.
