#include "EngineSession.h"

#include <chrono>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <vector>

#include <sys/stat.h>
#include <unistd.h>

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/session_stats.hpp>
#include <libtorrent/write_resume_data.hpp>

#include "EngineConfiguration.h"
#include "EngineSupport.h"

namespace lt = libtorrent;
namespace fs = std::filesystem;
using namespace std::chrono_literals;

using namespace NativeEngine;

CBTEngine::CBTEngine(const fs::path &profile, NSDictionary *configured)
    : profilePath {profile}
    , resumePath {profile / "ResumeData"}
    , session {configurationSettings(configured)}
    , configuration {configured}
{
    fs::create_directories(resumePath);
    ::chmod(profilePath.c_str(), 0700);
    ::chmod(resumePath.c_str(), 0700);
    restore();
    for (const lt::torrent_handle &handle : session.get_torrents())
        configureTorrent(handle);
}

lt::torrent_handle CBTEngine::find(const char *id)
{
    const std::string wanted = requiredString(id, "Torrent ID");
    const auto found = handlesByID.find(wanted);
    if (found != handlesByID.end() && found->second.is_valid())
        return found->second;
    throw std::runtime_error("The selected torrent no longer exists");
}

std::string CBTEngine::torrentID(const lt::torrent_handle &handle)
{
    const auto found = torrentIDs.find(handle);
    if (found != torrentIDs.end())
        return found->second;
    const std::string id = hashString(handle.info_hashes());
    torrentIDs.emplace(handle, id);
    handlesByID.emplace(id, handle);
    return id;
}

void CBTEngine::report(const std::string &message)
{
    if (errors.size() >= 100)
        errors.erase(errors.begin());
    errors.push_back(message);
}

void CBTEngine::restore()
{
    for (const fs::directory_entry &entry : fs::directory_iterator(resumePath))
    {
        if (!entry.is_regular_file() || entry.path().extension() != ".fastresume")
            continue;
        try
        {
            const auto size = fs::file_size(entry.path());
            if (size > 64 * 1024 * 1024)
                throw std::runtime_error("Resume file exceeds the 64 MiB safety limit");
            std::ifstream input(entry.path(), std::ios::binary);
            std::vector<char> bytes((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
            if (!input || bytes.empty())
                throw std::runtime_error("Cannot read resume data");
            lt::error_code error;
            lt::add_torrent_params params = lt::read_resume_data(bytes, error);
            if (error)
                throw std::runtime_error(error.message());
            if (params.save_path.empty())
                throw std::runtime_error("Resume data has no save path");
            params.flags |= lt::torrent_flags::duplicate_is_error;
            // Apply per-task policy before adding the handle: restored peers must
            // not briefly use an old PeX or connection configuration.
            configureParameters(params);
            if (![configuration[@"queueEnabled"] boolValue] && (params.flags & lt::torrent_flags::auto_managed))
                params.flags &= ~(lt::torrent_flags::auto_managed | lt::torrent_flags::paused);
            const lt::torrent_handle handle = session.add_torrent(std::move(params), error);
            if (error)
                throw std::runtime_error(error.message());
            torrentIDs.emplace(handle, entry.path().stem().string());
            handlesByID.emplace(entry.path().stem().string(), handle);
        }
        catch (const std::exception &error)
        {
            report("Could not restore " + entry.path().filename().string() + ": " + error.what());
        }
    }
}

lt::torrent_flags_t CBTEngine::policyFlags() const
{
    lt::torrent_flags_t flags;
    if (![configuration[@"enablePeX"] boolValue])
        flags |= lt::torrent_flags::disable_pex;
    if ([configuration[@"sequentialDownloads"] boolValue])
        flags |= lt::torrent_flags::sequential_download;
    return flags;
}

int CBTEngine::connectionLimit() const
{
    const int limit = [configuration[@"maxConnectionsPerTorrent"] intValue];
    return limit == 0 ? -1 : limit;
}

void CBTEngine::configureParameters(lt::add_torrent_params &params) const
{
    params.flags &= ~(lt::torrent_flags::disable_pex | lt::torrent_flags::sequential_download);
    params.flags |= policyFlags();
    params.max_connections = connectionLimit();
}

void CBTEngine::configureTorrent(const lt::torrent_handle &handle)
{
    const lt::torrent_status status = handle.status();
    const bool queue = [configuration[@"queueEnabled"] boolValue];
    if (!queue && (status.flags & lt::torrent_flags::auto_managed))
    {
        handle.unset_flags(lt::torrent_flags::auto_managed);
        handle.resume();
    }
    else if (queue && !(status.flags & lt::torrent_flags::paused))
    {
        handle.set_flags(lt::torrent_flags::auto_managed);
    }
    // A manually paused task stays paused when unrelated settings change.
    const auto mask = lt::torrent_flags::disable_pex | lt::torrent_flags::sequential_download;
    handle.set_flags(policyFlags(), mask);
    handle.set_max_connections(connectionLimit());
}

void CBTEngine::applyConfiguration(NSDictionary *next)
{
    const lt::settings_pack settings = configurationSettings(next);
    session.apply_settings(settings);
    configuration = next;
    for (const lt::torrent_handle &handle : session.get_torrents())
    {
        configureTorrent(handle);
        requestSave(handle);
    }
    enforceSeedLimits();
}

void CBTEngine::enforceSeedLimits()
{
    const double ratioLimit = [configuration[@"seedRatioLimit"] doubleValue];
    const int timeLimit = [configuration[@"seedTimeLimitMinutes"] intValue];
    if (ratioLimit == 0 && timeLimit == 0)
        return;
    for (const lt::torrent_handle &handle : session.get_torrents())
    {
        const lt::torrent_status status = handle.status();
        if (!status.is_finished || (status.flags & lt::torrent_flags::paused))
            continue;
        const int64_t denominator = status.all_time_download > 0 ? status.all_time_download : status.total_wanted;
        const bool ratioReached = ratioLimit > 0 && denominator > 0
            && static_cast<double>(status.all_time_upload) / denominator >= ratioLimit;
        const bool timeReached = timeLimit > 0 && status.finished_duration.count() >= static_cast<int64_t>(timeLimit) * 60;
        if (ratioReached || timeReached)
        {
            handle.unset_flags(lt::torrent_flags::auto_managed);
            handle.pause();
            requestSave(handle);
        }
    }
}

void CBTEngine::processAlerts()
{
    std::vector<lt::alert *> alerts;
    session.pop_alerts(&alerts);
    for (const lt::alert *alert : alerts)
    {
        if (const auto *saved = lt::alert_cast<lt::save_resume_data_alert>(alert))
        {
            pendingSaves.erase(saved->handle);
            if (removedHandles.erase(saved->handle))
                continue;
            const std::string id = torrentID(saved->handle);
            try
            {
                atomicWrite(resumePath / (id + ".fastresume"), lt::write_resume_data_buf(saved->params));
            }
            catch (const std::exception &error)
            {
                saveFailed = true;
                dirtyHandles.insert(saved->handle);
                report(error.what());
            }
        }
        else if (const auto *failed = lt::alert_cast<lt::save_resume_data_failed_alert>(alert))
        {
            pendingSaves.erase(failed->handle);
            if (removedHandles.erase(failed->handle))
                continue;
            saveFailed = true;
            dirtyHandles.insert(failed->handle);
            report("Could not save a torrent: " + failed->error.message());
        }
        else if (const auto *stats = lt::alert_cast<lt::dht_stats_alert>(alert))
        {
            dhtNodes = 0;
            for (const lt::dht_routing_bucket &bucket : stats->routing_table)
                dhtNodes += bucket.num_nodes;
        }
        else if (const auto *stats = lt::alert_cast<lt::session_stats_alert>(alert))
        {
            const auto counters = stats->counters();
            const int received = lt::find_metric_idx("net.recv_payload_bytes");
            const int sent = lt::find_metric_idx("net.sent_payload_bytes");
            if (received >= 0 && received < counters.size())
                totalDownloaded = counters[received];
            if (sent >= 0 && sent < counters.size())
                totalUploaded = counters[sent];
        }
        else if (const auto *failure = lt::alert_cast<lt::torrent_error_alert>(alert))
        {
            report(failure->message());
        }
        else if (const auto *failure = lt::alert_cast<lt::torrent_delete_failed_alert>(alert))
        {
            report(failure->message());
        }
        else if (const auto *failure = lt::alert_cast<lt::listen_failed_alert>(alert))
        {
            report(failure->message());
        }
    }
    enforceSeedLimits();
}

void CBTEngine::requestSave(const lt::torrent_handle &handle)
{
    dirtyHandles.insert(handle);
}

void CBTEngine::queueSave(const lt::torrent_handle &handle)
{
    torrentID(handle);
    if (pendingSaves.insert(handle).second)
    {
        try
        {
            handle.save_resume_data(lt::torrent_handle::save_info_dict);
            dirtyHandles.erase(handle);
        }
        catch (...)
        {
            pendingSaves.erase(handle);
            dirtyHandles.insert(handle);
            throw;
        }
    }
}

void CBTEngine::requestSaves()
{
    for (const lt::torrent_handle &handle : session.get_torrents())
        queueSave(handle);
    lastSave = std::chrono::steady_clock::now();
}

void CBTEngine::save(bool all)
{
    processAlerts();
    saveFailed = false;
    const auto deadline = std::chrono::steady_clock::now() + 15s;
    auto drain = [&]
    {
        while (!pendingSaves.empty() && std::chrono::steady_clock::now() < deadline)
        {
            session.wait_for_alert(100ms);
            processAlerts();
        }
        if (!pendingSaves.empty())
            throw std::runtime_error("Timed out waiting for torrent resume data");
    };
    // Finish older snapshots before requesting the current pause/priority state.
    drain();
    if (all)
        requestSaves();
    else
    {
        const auto dirty = dirtyHandles;
        for (const auto &handle : dirty)
            queueSave(handle);
    }
    drain();
    if (saveFailed)
        throw std::runtime_error("Some task state could not be saved; check the application log");
}
