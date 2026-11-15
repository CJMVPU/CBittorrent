# Upload investigation — 2026-11-15

## Observed result

No reproducible general upload failure was found. During the read-only inspection,
CBittorrent 0.8.0 initially showed zero uploaded bytes in this session, then reached
9.2 MiB without changing its settings, restarting it or changing its routing. The
completed task increased from roughly 126 MiB to 135 MiB uploaded. This establishes
real upload activity, not the cause of every idle interval or a throughput target.

The installed qBittorrent binary reports 5.2.3. Its visible task list was empty and
its transfer counters were zero at inspection. Consequently no same-swarm public
upload-speed A/B comparison with that binary is claimed. Both applications remained
running; neither configuration, network policy nor existing task was changed.

## Source and settings comparison

The retained upstream source (`src/base/bittorrent/sessionimpl.cpp` and
`peerinfo.cpp`, source-file history commit `d56ce79c9`) is a reference baseline,
not proof of the installed 5.2.3 binary's effective defaults.

| Area | Native application | Retained qBittorrent reference |
| --- | --- | --- |
| Global upload slots | Saved value 8 | Default 20 |
| Per-task upload slots | Unlimited | Default 4 |
| Upload-slot selection | Fixed slots | Fixed slots by default |
| Seed scheduling | libtorrent default round-robin | Fastest-upload by default |
| Transports | TCP and uTP enabled | Both enabled by default |
| Peer interested/choked flags | `remote_interested`, `choked` | Same libtorrent flags |
| Listen port | Automatic, potentially different per interface | One configured port; installed instance listened on 6476 |
| Network interface binding | Wildcard listening; OS routes outbound traffic | Supports interface and outgoing-address binding |
| Peer identity | libtorrent default fingerprint; CBittorrent user agent | qBittorrent fingerprint and user agent |

Differences are not automatically defects. Slot counts and seed scheduling cannot
create demand from an uninterested peer. No fingerprint impersonation, arbitrary
slot increase or routing change was applied to mask the symptom.

The three existing native resume records were read without modifying them. All
showed `paused=0`, `auto_managed=1`, `upload_mode=0`, `share_mode=0`,
`super_seeding=0`, and unlimited per-task upload rate/slots. Global upload rate
was unlimited. The completed task's ratio was below the configured 1.5 stop limit.

## Live peer and network evidence

The completed task repeatedly had pending TCP handshakes. An established sampled
peer advertised no remote interest and transferred no data. Thus a displayed
connection count is not a count of active download requests. Previous downloading
task inspection also found complete seeds with no interest in our pieces.

Observed native TCP sockets used a TUN address. qBittorrent's log also showed the
same class of TUN interface, successful UPnP mappings, then later mapping failures
(`no router found`). This is evidence of changing mapping/interface conditions,
not proof that the proxy blocks BitTorrent or that all incoming traffic fails.
Earlier native observations included incoming uTP peers. No public reachability
probe, proxy-bypass experiment or router configuration change was performed.

## Reproducible controlled comparison

`native/tests/upload_interop.cpp`, called by `native/tests/run.sh`, uses private
synthetic torrents, isolated temporary directories and loopback-only sessions.
DHT, trackers, discovery and router mapping are disabled. It compares:

- Native sender, TCP only, independent libtorrent receiver: 262144 bytes verified.
- Native sender, uTP only, independent libtorrent receiver: 262144 bytes verified.
- Reference-policy sender, TCP only: 262144 bytes verified.
- Reference-policy sender, uTP only: 262144 bytes verified.

The reference-policy sender applies the retained qBittorrent defaults for fixed
slots, fastest-upload scheduling, 20 global slots and 4 per-task slots. It uses
the local libtorrent library, **not the installed qBittorrent binary**. All four
cases verified the complete received bytes and sender upload accounting. The
native cases also cover metadata preview, confirmation, add-paused and resume
with existing complete content. These tests rule out a general inability to serve
an interested peer over either transport, including through the new add workflow.
They do not benchmark WAN performance, different libtorrent versions, router
reachability, swarm popularity, or many-peer scheduling under load.

Local evidence is retained in `build/upload-investigation-2026-11-15/verification.log`.
Run `native/tests/run.sh` to repeat the checks; they also run in normal CI.

## Remaining uncertainty

The immediate observed constraint was lack of an established interested downloader,
with frequent pending handshakes. Root causes of individual failed handshakes remain
unverified. A conclusive WAN A/B comparison needs the same controlled downloader,
network path and source data for both actual clients, in separate storage, plus
peer-disconnect/handshake reason collection. Changing or bypassing the user's TUN
without an explicit routing decision would confound the comparison and may expose
a different network identity. No claim of fixing a proven upload-engine bug is made.
