#include "CBTEngine.h"

#include <cstdlib>
#include <filesystem>
#include <memory>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/download_priority.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/torrent_info.hpp>

#include "EngineConfiguration.h"
#include "EngineSession.h"
#include "EngineSupport.h"

namespace lt = libtorrent;
namespace fs = std::filesystem;
using namespace std::chrono_literals;

using namespace NativeEngine;


namespace
{
    template <typename Function>
    int perform(CBTEngine *engine, char **error, Function function)
    {
        if (error)
            *error = nullptr;
        try
        {
            if (!engine)
                throw std::invalid_argument("The download engine is unavailable");
            const std::lock_guard<std::mutex> lock(engine->mutex);
            engine->processAlerts();
            function(*engine);
            return 1;
        }
        catch (const std::exception &failure)
        {
            if (error)
                *error = copyString(failure.what());
            return 0;
        }
    }
}

CBTEngine *cbt_engine_create(const char *profilePath, char **error)
{
    return cbt_engine_create_configured(profilePath, "{}", error);
}

CBTEngine *cbt_engine_create_configured(const char *profilePath, const char *settingsJSON, char **error)
{
    @autoreleasepool
    {
        if (error)
            *error = nullptr;
        try
        {
            const fs::path path = fs::absolute(requiredString(profilePath, "Profile path"));
            NSDictionary *configured = validatedConfiguration(defaultConfiguration(), settingsJSON);
            // A bundled OpenSSL must not depend on the build machine's Homebrew CA path.
            // Keep an explicit user override and retain normal certificate verification.
            if (!std::getenv("SSL_CERT_FILE") && fs::is_regular_file("/etc/ssl/cert.pem"))
                ::setenv("SSL_CERT_FILE", "/etc/ssl/cert.pem", 0);
            // Configure the session before it can create network sockets or restore tasks.
            return new CBTEngine(path, configured);
        }
        catch (const std::exception &failure)
        {
            if (error)
                *error = copyString(failure.what());
            return nullptr;
        }
    }
}

void cbt_engine_destroy(CBTEngine *engine)
{
    if (!engine)
        return;
    char *error = nullptr;
    cbt_engine_save(engine, &error);
    if (error)
    {
        NSLog(@"CBittorrent shutdown save: %s", error);
        cbt_string_free(error);
    }
    delete engine;
}

void cbt_engine_release(CBTEngine *engine)
{
    delete engine;
}

int cbt_engine_add(CBTEngine *engine, const char *source, const char *savePath, int paused, char **error)
{
    return perform(engine, error, [&](CBTEngine &state)
    {
        const std::string input = requiredString(source, "Torrent source");
        const fs::path destination = fs::absolute(requiredString(savePath, "Save path"));
        fs::create_directories(destination);
        lt::error_code failure;
        lt::add_torrent_params params;
        if (input.starts_with("magnet:"))
            params = lt::parse_magnet_uri(input, failure);
        else
            params = lt::load_torrent_file(input);
        if (failure)
            throw std::runtime_error(failure.message());
        if ([state.configuration[@"autoAddTrackers"] boolValue])
        {
            std::set<std::string> existing(params.trackers.begin(), params.trackers.end());
            params.tracker_tiers.resize(params.trackers.size(), 0);
            for (const std::string &url : defaultTrackers(state.configuration))
            {
                if (existing.insert(url).second)
                {
                    params.trackers.push_back(url);
                    params.tracker_tiers.push_back(0);
                }
            }
        }
        params.save_path = destination.string();
        params.flags |= lt::torrent_flags::duplicate_is_error;
        params.storage_mode = [state.configuration[@"preallocateFiles"] boolValue] ? lt::storage_mode_allocate : lt::storage_mode_sparse;
        state.configureParameters(params);
        if (![state.configuration[@"queueEnabled"] boolValue])
            params.flags &= ~lt::torrent_flags::auto_managed;
        if (paused)
        {
            params.flags |= lt::torrent_flags::paused;
            params.flags &= ~lt::torrent_flags::auto_managed;
        }
        else
        {
            params.flags &= ~lt::torrent_flags::paused;
        }
        lt::torrent_handle handle = state.session.add_torrent(std::move(params), failure);
        if (failure)
            throw std::runtime_error(failure.message());
        state.torrentID(handle);
        state.requestSave(handle);
    });
}

int cbt_engine_pause(CBTEngine *engine, const char *torrentID, char **error)
{
    return perform(engine, error, [&](CBTEngine &state)
    {
        lt::torrent_handle handle = state.find(torrentID);
        handle.unset_flags(lt::torrent_flags::auto_managed);
        handle.pause();
        state.requestSave(handle);
    });
}

int cbt_engine_resume(CBTEngine *engine, const char *torrentID, char **error)
{
    return perform(engine, error, [&](CBTEngine &state)
    {
        lt::torrent_handle handle = state.find(torrentID);
        handle.clear_error();
        if ([state.configuration[@"queueEnabled"] boolValue])
            handle.set_flags(lt::torrent_flags::auto_managed);
        else
            handle.unset_flags(lt::torrent_flags::auto_managed);
        handle.resume();
        state.requestSave(handle);
    });
}

int cbt_engine_remove(CBTEngine *engine, const char *torrentID, int deleteFiles, char **error)
{
    return perform(engine, error, [&](CBTEngine &state)
    {
        lt::torrent_handle handle = state.find(torrentID);
        const std::string id = state.torrentID(handle);
        // Remove persisted state first. If that fails, leave the live task intact.
        fs::remove(state.resumePath / (id + ".fastresume"));
        // A tombstone is needed only while an outstanding resume alert can arrive.
        if (state.pendingSaves.erase(handle))
            state.removedHandles.insert(handle);
        state.dirtyHandles.erase(handle);
        state.handlesByID.erase(id);
        state.torrentIDs.erase(handle);
        state.session.remove_torrent(handle, deleteFiles ? lt::session::delete_files : lt::remove_flags_t{});
    });
}

int cbt_engine_apply_settings(CBTEngine *engine, const char *json, char **error)
{
    @autoreleasepool
    {
        return perform(engine, error, [&](CBTEngine &state)
        {
            // Validate every supplied field before changing any live setting.
            NSDictionary *next = validatedConfiguration(state.configuration, json);
            state.applyConfiguration(next);
        });
    }
}

int cbt_engine_apply_default_trackers(CBTEngine *engine, int *changedCount, char **error)
{
    if (changedCount)
        *changedCount = 0;
    return perform(engine, error, [&](CBTEngine &state)
    {
        const auto configured = defaultTrackers(state.configuration);
        int changed = 0;
        for (const lt::torrent_handle &handle : state.session.get_torrents())
        {
            std::set<std::string> existing;
            for (const auto &tracker : handle.trackers())
                existing.insert(tracker.url);
            bool added = false;
            for (const std::string &url : configured)
            {
                if (existing.insert(url).second)
                {
                    handle.add_tracker(lt::announce_entry(url));
                    added = true;
                }
            }
            if (added)
            {
                ++changed;
                state.requestSave(handle);
            }
        }
        if (changedCount)
            *changedCount = changed;
    });
}

int cbt_engine_set_file_priority(CBTEngine *engine, const char *torrentID, int fileIndex, int priority, char **error)
{
    return perform(engine, error, [&](CBTEngine &state)
    {
        lt::torrent_handle handle = state.find(torrentID);
        const std::shared_ptr<const lt::torrent_info> info = handle.torrent_file();
        if (!info || fileIndex < 0 || fileIndex >= info->num_files() || priority < 0 || priority > 7)
            throw std::invalid_argument("Invalid file index or priority");
        handle.file_priority(lt::file_index_t(fileIndex), lt::download_priority_t(priority));
        state.requestSave(handle);
    });
}

int cbt_engine_save(CBTEngine *engine, char **error)
{
    return perform(engine, error, [](CBTEngine &state) { state.save(); });
}

int cbt_engine_flush(CBTEngine *engine, char **error)
{
    return perform(engine, error, [](CBTEngine &state) { state.save(false); });
}

int cbt_engine_connect_peer(CBTEngine *engine, const char *torrentID, const char *address, int port, char **error)
{
    return perform(engine, error, [&](CBTEngine &state)
    {
        if (port < 1 || port > 65535)
            throw std::invalid_argument("Peer port is out of range");
        lt::error_code failure;
        const lt::address peer = lt::make_address(requiredString(address, "Peer address"), failure);
        if (failure)
            throw std::invalid_argument(failure.message());
        state.find(torrentID).connect_peer(lt::tcp::endpoint(peer, static_cast<unsigned short>(port)));
    });
}

void cbt_string_free(char *string)
{
    std::free(string);
}
