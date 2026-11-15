#include "EngineSession.h"

#include <algorithm>
#include <chrono>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

#include <libtorrent/download_priority.hpp>
#include <libtorrent/torrent_info.hpp>

#include "EngineSupport.h"

namespace lt = libtorrent;
namespace fs = std::filesystem;
using namespace std::chrono_literals;

using namespace NativeEngine;

static char *snapshotJSON(CBTEngine *engine, const char *selectedID, bool includeDetails)
{
    @autoreleasepool
    {
        try
        {
            if (!engine)
                throw std::invalid_argument("Engine unavailable");
            const std::lock_guard<std::mutex> lock(engine->mutex);
            engine->processAlerts();
            engine->session.post_session_stats();
            if (std::chrono::steady_clock::now() - engine->lastSave >= 30s)
                engine->requestSaves();
            if (std::chrono::steady_clock::now() - engine->lastDHT >= 5s)
            {
                engine->session.post_dht_stats();
                engine->lastDHT = std::chrono::steady_clock::now();
            }
            NSMutableArray *torrents = [NSMutableArray array];
            int64_t downloadRate = 0;
            int64_t uploadRate = 0;
            const std::vector<lt::torrent_handle> handles = selectedID
                ? std::vector<lt::torrent_handle>{engine->find(selectedID)} : engine->session.get_torrents();
            for (const lt::torrent_handle &handle : handles)
            {
                const lt::torrent_status status = handle.status();
                const int64_t remaining = std::max<int64_t>(0, status.total_wanted - status.total_wanted_done);
                const int64_t eta = status.is_finished ? 0 : (status.download_payload_rate > 0 ? remaining / status.download_payload_rate : -1);
                const int64_t ratioBytes = status.all_time_download > 0 ? status.all_time_download : status.total_wanted;
                const double ratio = ratioBytes > 0 ? static_cast<double>(status.all_time_upload) / ratioBytes : 0;
                NSMutableArray *files = [NSMutableArray array];
                if (const std::shared_ptr<const lt::torrent_info> info = includeDetails ? handle.torrent_file() : nullptr)
                {
                    const std::vector<int64_t> progress = handle.file_progress();
                    const std::vector<lt::download_priority_t> priorities = handle.get_file_priorities();
                    const auto &storage = info->layout();
                    for (int i = 0; i < storage.num_files(); ++i)
                    {
                        const lt::file_index_t index(i);
                        const int64_t size = storage.file_size(index);
                        const int64_t done = i < static_cast<int>(progress.size()) ? progress[i] : 0;
                        [files addObject:@{@"index": @(i), @"path": stringValue(storage.file_path(index)),
                            @"size": @(size), @"progress": @(size > 0 ? static_cast<double>(done) / size : 1.0),
                            @"priority": @(i < static_cast<int>(priorities.size()) ? static_cast<std::uint8_t>(priorities[i]) : 4)}];
                    }
                }
                NSMutableArray *trackers = [NSMutableArray array];
                if (includeDetails)
                    for (const lt::announce_entry &tracker : handle.trackers())
                        [trackers addObject:@{@"url": stringValue(tracker.url), @"status": @"configured"}];
                [torrents addObject:@{@"id": stringValue(engine->torrentID(handle)), @"name": stringValue(status.name),
                    @"state": stringValue(stateName(status)), @"progress": @(status.progress), @"totalSize": @(status.total_wanted),
                    @"downloaded": @(status.total_wanted_done), @"uploaded": @(status.all_time_upload),
                    @"downloadRate": @(status.download_payload_rate), @"uploadRate": @(status.upload_payload_rate),
                    @"eta": @(eta), @"ratio": @(ratio), @"peers": @(status.num_peers), @"seeds": @(status.num_seeds),
                    @"savePath": stringValue(status.save_path), @"error": stringValue(status.errc ? status.errc.message() : ""),
                    @"files": files, @"trackers": trackers}];
                downloadRate += status.download_payload_rate;
                uploadRate += status.upload_payload_rate;
            }
            NSMutableArray *errors = [NSMutableArray array];
            for (const std::string &message : engine->errors)
                [errors addObject:stringValue(message)];
            NSDictionary *snapshot = @{@"torrents": torrents, @"downloadRate": @(downloadRate), @"uploadRate": @(uploadRate),
                @"totalDownloaded": @(engine->totalDownloaded), @"totalUploaded": @(engine->totalUploaded), @"dhtNodes": @(engine->dhtNodes),
                @"listenPort": @(engine->session.listen_port()), @"errors": errors};
            NSError *error = nil;
            NSData *json = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:&error];
            if (!json)
                throw std::runtime_error(error.localizedDescription.UTF8String ?: "Cannot serialize task state");
            if (!selectedID)
                engine->errors.clear();
            return copyString(std::string(static_cast<const char *>(json.bytes), json.length));
        }
        catch (const std::exception &failure)
        {
            if (engine && !selectedID)
            {
                const std::lock_guard<std::mutex> lock(engine->mutex);
                engine->report(failure.what());
            }
            return nullptr;
        }
    }
}

char *cbt_engine_snapshot_json(CBTEngine *engine)
{
    return snapshotJSON(engine, nullptr, true);
}

char *cbt_engine_summary_json(CBTEngine *engine)
{
    return snapshotJSON(engine, nullptr, false);
}

char *cbt_engine_detail_json(CBTEngine *engine, const char *torrentID)
{
    if (!torrentID || !*torrentID)
        return nullptr;
    return snapshotJSON(engine, torrentID, true);
}

char *cbt_engine_settings_json(CBTEngine *engine)
{
    @autoreleasepool
    {
        if (!engine)
            return nullptr;
        const std::lock_guard<std::mutex> lock(engine->mutex);
        const lt::settings_pack effective = engine->session.get_settings();
        NSMutableDictionary *result = [engine->configuration mutableCopy];
        result[@"bookkeeping"] = @{@"identities": @(engine->torrentIDs.size()),
            @"lookupEntries": @(engine->handlesByID.size()), @"removedPendingSaves": @(engine->removedHandles.size())};
        result[@"effective"] = @{
            @"downloadRateLimit": @(effective.get_int(lt::settings_pack::download_rate_limit)),
            @"uploadRateLimit": @(effective.get_int(lt::settings_pack::upload_rate_limit)),
            @"connectionsLimit": @(effective.get_int(lt::settings_pack::connections_limit)),
            @"uploadSlots": @(effective.get_int(lt::settings_pack::unchoke_slots_limit)),
            @"activeDownloads": @(effective.get_int(lt::settings_pack::active_downloads)),
            @"activeSeeds": @(effective.get_int(lt::settings_pack::active_seeds)),
            @"activeTorrents": @(effective.get_int(lt::settings_pack::active_limit)),
            @"enableDHT": @(effective.get_bool(lt::settings_pack::enable_dht)),
            @"enableLSD": @(effective.get_bool(lt::settings_pack::enable_lsd)),
            @"enableUPnP": @(effective.get_bool(lt::settings_pack::enable_upnp)),
            @"enableNATPMP": @(effective.get_bool(lt::settings_pack::enable_natpmp)),
            @"incomingTCP": @(effective.get_bool(lt::settings_pack::enable_incoming_tcp)),
            @"incomingUTP": @(effective.get_bool(lt::settings_pack::enable_incoming_utp)),
            @"encryptionPolicy": @(effective.get_int(lt::settings_pack::in_enc_policy)),
            @"proxyType": @(effective.get_int(lt::settings_pack::proxy_type)),
            @"listenInterfaces": stringValue(effective.get_str(lt::settings_pack::listen_interfaces))};
        NSMutableArray *torrents = [NSMutableArray array];
        for (const lt::torrent_handle &handle : engine->session.get_torrents())
        {
            const auto status = handle.status();
            [torrents addObject:@{@"id": stringValue(engine->torrentID(handle)),
                @"maxConnections": @(handle.max_connections()),
                @"sequentialDownloads": @(bool(status.flags & lt::torrent_flags::sequential_download)),
                @"enablePeX": @(!bool(status.flags & lt::torrent_flags::disable_pex)),
                @"autoManaged": @(bool(status.flags & lt::torrent_flags::auto_managed)),
                @"preallocateFiles": @(status.storage_mode == lt::storage_mode_allocate)}];
        }
        result[@"torrents"] = torrents;
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        if (!data)
            return nullptr;
        return copyString(std::string(static_cast<const char *>(data.bytes), data.length));
    }
}

