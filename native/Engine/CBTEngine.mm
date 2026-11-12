#include "CBTEngine.h"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/download_priority.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_stats.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/write_resume_data.hpp>

#import <Foundation/Foundation.h>

namespace lt = libtorrent;
namespace fs = std::filesystem;
using namespace std::chrono_literals;

namespace
{
    char *copyString(const std::string &value)
    {
        char *result = static_cast<char *>(std::malloc(value.size() + 1));
        if (result)
            std::memcpy(result, value.c_str(), value.size() + 1);
        return result;
    }

    NSString *stringValue(const std::string &value)
    {
        NSString *result = [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
        return result ?: @"";
    }

    std::string requiredString(const char *value, const char *name)
    {
        if (!value || !*value)
            throw std::invalid_argument(std::string(name) + " must not be empty");
        return value;
    }

    std::string hashString(const lt::info_hash_t &hashes)
    {
        const bool v2 = hashes.has_v2();
        const char *bytes = v2 ? hashes.v2.data() : hashes.v1.data();
        const int size = v2 ? 32 : 20;
        constexpr char hex[] = "0123456789abcdef";
        std::string result = v2 ? "v2-" : "v1-";
        for (int i = 0; i < size; ++i)
        {
            const unsigned char byte = static_cast<unsigned char>(bytes[i]);
            result += hex[byte >> 4];
            result += hex[byte & 15];
        }
        return result;
    }

    void atomicWrite(const fs::path &path, const std::vector<char> &bytes)
    {
        std::string temporary = path.string() + ".tmp.XXXXXX";
        std::vector<char> name(temporary.begin(), temporary.end());
        name.push_back('\0');
        const int fd = ::mkstemp(name.data());
        if (fd < 0)
            throw std::runtime_error("Cannot create resume data: " + path.string());
        bool closed = false;
        try
        {
            size_t offset = 0;
            while (offset < bytes.size())
            {
                const ssize_t written = ::write(fd, bytes.data() + offset, bytes.size() - offset);
                if (written < 0 && errno == EINTR)
                    continue;
                if (written <= 0)
                    throw std::runtime_error("Cannot write resume data: " + path.string());
                offset += static_cast<size_t>(written);
            }
            if (::fsync(fd) != 0)
                throw std::runtime_error("Cannot flush resume data: " + path.string());
            ::close(fd);
            closed = true;
            if (::rename(name.data(), path.c_str()) != 0)
                throw std::runtime_error("Cannot replace resume data: " + path.string());
        }
        catch (...)
        {
            if (!closed)
                ::close(fd);
            ::unlink(name.data());
            throw;
        }
    }

    lt::settings_pack initialSettings()
    {
        lt::settings_pack settings;
        settings.set_str(lt::settings_pack::user_agent, "CBittorrent/0.1.0");
        settings.set_int(lt::settings_pack::alert_mask,
            static_cast<std::uint32_t>(lt::alert_category::error | lt::alert_category::storage | lt::alert_category::status));
        settings.set_int(lt::settings_pack::active_downloads, 3);
        settings.set_int(lt::settings_pack::active_seeds, 5);
        settings.set_int(lt::settings_pack::active_limit, 8);
        if (std::getenv("CBT_ENGINE_LOCAL_ONLY"))
        {
            settings.set_str(lt::settings_pack::listen_interfaces, "127.0.0.1:0");
            settings.set_bool(lt::settings_pack::enable_dht, false);
            settings.set_bool(lt::settings_pack::enable_lsd, false);
            settings.set_bool(lt::settings_pack::enable_upnp, false);
            settings.set_bool(lt::settings_pack::enable_natpmp, false);
            settings.set_bool(lt::settings_pack::allow_multiple_connections_per_ip, true);
        }
        else
        {
            settings.set_str(lt::settings_pack::listen_interfaces, "0.0.0.0:0,[::]:0");
        }
        return settings;
    }

    std::string stateName(const lt::torrent_status &status)
    {
        if (status.errc)
            return "error";
        if (status.flags & lt::torrent_flags::paused)
            return (status.flags & lt::torrent_flags::auto_managed) ? "queued" : "paused";
        if (status.state == lt::torrent_status::checking_files || status.state == lt::torrent_status::checking_resume_data)
            return "checking";
        if (!status.has_metadata)
            return "metadata";
        if (status.is_seeding || status.is_finished)
            return "seeding";
        return "downloading";
    }
}

struct CBTEngine
{
    explicit CBTEngine(const fs::path &profile)
        : profilePath {profile}
        , resumePath {profile / "ResumeData"}
        , session {initialSettings()}
    {
        fs::create_directories(resumePath);
        ::chmod(profilePath.c_str(), 0700);
        ::chmod(resumePath.c_str(), 0700);
        restore();
    }

    lt::torrent_handle find(const char *id)
    {
        const std::string wanted = requiredString(id, "Torrent ID");
        for (const lt::torrent_handle &handle : session.get_torrents())
        {
            if (torrentID(handle) == wanted)
                return handle;
        }
        throw std::runtime_error("The selected torrent no longer exists");
    }

    std::string torrentID(const lt::torrent_handle &handle)
    {
        const auto found = torrentIDs.find(handle);
        if (found != torrentIDs.end())
            return found->second;
        return torrentIDs.emplace(handle, hashString(handle.info_hashes())).first->second;
    }

    void report(const std::string &message)
    {
        if (errors.size() >= 100)
            errors.erase(errors.begin());
        errors.push_back(message);
    }

    void restore()
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
                const lt::torrent_handle handle = session.add_torrent(std::move(params), error);
                if (error)
                    throw std::runtime_error(error.message());
                torrentIDs.emplace(handle, entry.path().stem().string());
            }
            catch (const std::exception &error)
            {
                report("Could not restore " + entry.path().filename().string() + ": " + error.what());
            }
        }
    }

    void processAlerts()
    {
        std::vector<lt::alert *> alerts;
        session.pop_alerts(&alerts);
        for (const lt::alert *alert : alerts)
        {
            if (const auto *saved = lt::alert_cast<lt::save_resume_data_alert>(alert))
            {
                const std::string id = torrentID(saved->handle);
                pendingSaves.erase(saved->handle);
                if (removedHandles.count(saved->handle))
                    continue;
                try
                {
                    atomicWrite(resumePath / (id + ".fastresume"), lt::write_resume_data_buf(saved->params));
                }
                catch (const std::exception &error)
                {
                    saveFailed = true;
                    report(error.what());
                }
            }
            else if (const auto *failed = lt::alert_cast<lt::save_resume_data_failed_alert>(alert))
            {
                pendingSaves.erase(failed->handle);
                if (removedHandles.count(failed->handle))
                    continue;
                saveFailed = true;
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
    }

    void requestSave(const lt::torrent_handle &handle)
    {
        torrentID(handle);
        if (pendingSaves.insert(handle).second)
            handle.save_resume_data(lt::torrent_handle::save_info_dict);
    }

    void requestSaves()
    {
        for (const lt::torrent_handle &handle : session.get_torrents())
            requestSave(handle);
        lastSave = std::chrono::steady_clock::now();
    }

    void save()
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
        requestSaves();
        drain();
        if (saveFailed)
            throw std::runtime_error("Some task state could not be saved; check the application log");
    }

    std::mutex mutex;
    fs::path profilePath;
    fs::path resumePath;
    lt::session session;
    std::set<lt::torrent_handle> pendingSaves;
    std::map<lt::torrent_handle, std::string> torrentIDs;
    std::set<lt::torrent_handle> removedHandles;
    std::vector<std::string> errors;
    int dhtNodes = 0;
    int64_t totalDownloaded = 0;
    int64_t totalUploaded = 0;
    bool saveFailed = false;
    std::chrono::steady_clock::time_point lastSave = std::chrono::steady_clock::now();
    std::chrono::steady_clock::time_point lastDHT = std::chrono::steady_clock::now();
};

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
    if (error)
        *error = nullptr;
    try
    {
        const fs::path path = fs::absolute(requiredString(profilePath, "Profile path"));
        // A bundled OpenSSL must not depend on the build machine's Homebrew CA path.
        // Keep an explicit user override and retain normal certificate verification.
        if (!std::getenv("SSL_CERT_FILE") && fs::is_regular_file("/etc/ssl/cert.pem"))
            ::setenv("SSL_CERT_FILE", "/etc/ssl/cert.pem", 0);
        return new CBTEngine(path);
    }
    catch (const std::exception &failure)
    {
        if (error)
            *error = copyString(failure.what());
        return nullptr;
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

char *cbt_engine_snapshot_json(CBTEngine *engine)
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
            for (const lt::torrent_handle &handle : engine->session.get_torrents())
            {
                const lt::torrent_status status = handle.status();
                const int64_t remaining = std::max<int64_t>(0, status.total_wanted - status.total_wanted_done);
                const int64_t eta = status.is_finished ? 0 : (status.download_payload_rate > 0 ? remaining / status.download_payload_rate : -1);
                const double ratio = status.all_time_download > 0 ? static_cast<double>(status.all_time_upload) / status.all_time_download : 0;
                NSMutableArray *files = [NSMutableArray array];
                if (const std::shared_ptr<const lt::torrent_info> info = handle.torrent_file())
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
            engine->errors.clear();
            return copyString(std::string(static_cast<const char *>(json.bytes), json.length));
        }
        catch (const std::exception &failure)
        {
            if (engine)
            {
                const std::lock_guard<std::mutex> lock(engine->mutex);
                engine->report(failure.what());
            }
            return nullptr;
        }
    }
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
        params.save_path = destination.string();
        params.flags |= lt::torrent_flags::duplicate_is_error;
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
        handle.set_flags(lt::torrent_flags::auto_managed);
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
        state.removedHandles.insert(handle);
        state.pendingSaves.erase(handle);
        state.session.remove_torrent(handle, deleteFiles ? lt::session::delete_files : lt::remove_flags_t{});
    });
}

int cbt_engine_set_limits(CBTEngine *engine, int downloadBytesPerSecond, int uploadBytesPerSecond, char **error)
{
    return perform(engine, error, [&](CBTEngine &state)
    {
        if (downloadBytesPerSecond < 0 || uploadBytesPerSecond < 0)
            throw std::invalid_argument("Rate limits must not be negative");
        lt::settings_pack settings;
        settings.set_int(lt::settings_pack::download_rate_limit, downloadBytesPerSecond);
        settings.set_int(lt::settings_pack::upload_rate_limit, uploadBytesPerSecond);
        state.session.apply_settings(settings);
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
