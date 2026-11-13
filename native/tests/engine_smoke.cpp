#include "CBTEngine.h"

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <regex>
#include <set>
#include <sstream>
#include <stdexcept>
#include <thread>

#include <boost/property_tree/json_parser.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/write_resume_data.hpp>

namespace fs = std::filesystem;
namespace lt = libtorrent;
namespace pt = boost::property_tree;
using namespace std::chrono_literals;
using Engine = std::unique_ptr<CBTEngine, decltype(&cbt_engine_destroy)>;

namespace
{
    void require(bool condition, const std::string &message)
    {
        if (!condition)
            throw std::runtime_error(message);
    }

    template <typename Function>
    void call(Function function)
    {
        char *error = nullptr;
        const int result = function(&error);
        const std::string message = error ? error : "Engine call failed without an error";
        cbt_string_free(error);
        require(result == 1, message);
    }

    Engine create(const fs::path &profile)
    {
        char *error = nullptr;
        Engine engine(cbt_engine_create(profile.c_str(), &error), cbt_engine_destroy);
        const std::string message = error ? error : "Engine creation failed";
        cbt_string_free(error);
        require(engine != nullptr, message);
        return engine;
    }

    pt::ptree snapshot(CBTEngine *engine)
    {
        char *json = cbt_engine_snapshot_json(engine);
        require(json != nullptr, "Snapshot allocation failed");
        std::istringstream stream(json);
        cbt_string_free(json);
        pt::ptree result;
        pt::read_json(stream, result);
        return result;
    }

    pt::ptree settings(CBTEngine *engine)
    {
        char *json = cbt_engine_settings_json(engine);
        require(json != nullptr, "Settings snapshot failed");
        std::istringstream stream(json);
        cbt_string_free(json);
        pt::ptree result;
        pt::read_json(stream, result);
        return result;
    }

    void apply(CBTEngine *engine, const char *json)
    {
        call([&](char **error) { return cbt_engine_apply_settings(engine, json, error); });
    }

    template <typename Predicate>
    pt::ptree waitFor(CBTEngine *engine, Predicate predicate, std::chrono::seconds timeout = 20s)
    {
        const auto deadline = std::chrono::steady_clock::now() + timeout;
        while (std::chrono::steady_clock::now() < deadline)
        {
            pt::ptree state = snapshot(engine);
            if (predicate(state))
                return state;
            std::this_thread::sleep_for(100ms);
        }
        std::ostringstream state;
        pt::write_json(state, snapshot(engine), false);
        throw std::runtime_error("Engine state timeout: " + state.str());
    }

    const pt::ptree &firstTorrent(const pt::ptree &state)
    {
        const auto &torrents = state.get_child("torrents");
        require(torrents.size() == 1, "Expected exactly one torrent");
        return torrents.front().second;
    }

    std::set<std::string> trackerURLs(const pt::ptree &state)
    {
        std::set<std::string> result;
        const auto &trackers = firstTorrent(state).get_child("trackers");
        for (const auto &tracker : trackers)
            result.insert(tracker.second.get<std::string>("url"));
        require(result.size() == trackers.size(), "Duplicate trackers on a task");
        return result;
    }

    std::string readFile(const fs::path &path)
    {
        std::ifstream input(path, std::ios::binary);
        return std::string(std::istreambuf_iterator<char>(input), {});
    }
}

int main()
{
    fs::path root;
    try
    {
        // No tracker, DHT, local discovery or router traffic: both peers bind loopback.
        ::setenv("CBT_ENGINE_LOCAL_ONLY", "1", 1);
        char temporary[] = "/tmp/cbittorrent-engine-test.XXXXXX";
        require(::mkdtemp(temporary) != nullptr, "Cannot create test directory");
        root = temporary;
        fs::create_directories(root / "seed");
        std::string payload(512 * 1024, '\0');
        for (size_t i = 0; i < payload.size(); ++i)
            payload[i] = static_cast<char>((i * 37 + i / 251) % 256);
        {
            std::ofstream file(root / "seed/payload.bin", std::ios::binary);
            file.write(payload.data(), payload.size());
        }
        lt::create_torrent torrent({lt::create_file_entry("payload.bin", payload.size())}, 16 * 1024);
        lt::set_piece_hashes(torrent, (root / "seed").string());
        std::vector<char> torrentBytes;
        lt::bencode(std::back_inserter(torrentBytes), torrent.generate());
        const fs::path torrentPath = root / "fixture.torrent";
        {
            std::ofstream file(torrentPath, std::ios::binary);
            file.write(torrentBytes.data(), torrentBytes.size());
        }
        // Tracker policy uses paused tasks and loopback addresses, never public trackers.
        {
            torrent.add_tracker("http://127.0.0.1:9/original");
            std::vector<char> trackedBytes;
            lt::bencode(std::back_inserter(trackedBytes), torrent.generate());
            const fs::path trackedPath = root / "tracked.torrent";
            {
                std::ofstream file(trackedPath, std::ios::binary);
                file.write(trackedBytes.data(), trackedBytes.size());
            }
            char *failure = nullptr;
            Engine tracked(cbt_engine_create_configured((root / "tracker-profile").c_str(),
                R"({"autoAddTrackers":true,"defaultTrackers":" http://127.0.0.1:9/original \n\nudp://127.0.0.1:9/added\nudp://127.0.0.1:9/added"})",
                &failure), cbt_engine_destroy);
            require(tracked != nullptr, failure ? failure : "Tracker session creation failed");
            cbt_string_free(failure);
            call([&](char **error) { return cbt_engine_add(tracked.get(), trackedPath.c_str(), (root / "tracked").c_str(), 1, error); });
            const std::set<std::string> initial {"http://127.0.0.1:9/original", "udp://127.0.0.1:9/added"};
            require(trackerURLs(snapshot(tracked.get())) == initial, "Automatic trackers lost original torrent trackers or duplicates were added");
            apply(tracked.get(), R"({"autoAddTrackers":false,"defaultTrackers":"https://127.0.0.1:9/manual"})");
            require(trackerURLs(snapshot(tracked.get())) == initial, "Saving settings retroactively modified existing trackers");
            int changed = -1;
            call([&](char **error) { return cbt_engine_apply_default_trackers(tracked.get(), &changed, error); });
            require(changed == 1, "Explicit tracker operation did not report the changed task");
            const std::set<std::string> expanded {"http://127.0.0.1:9/original", "udp://127.0.0.1:9/added", "https://127.0.0.1:9/manual"};
            require(trackerURLs(snapshot(tracked.get())) == expanded, "Explicit append replaced an existing tracker");
            call([&](char **error) { return cbt_engine_apply_default_trackers(tracked.get(), &changed, error); });
            require(changed == 0 && trackerURLs(snapshot(tracked.get())) == expanded, "Applying trackers twice was not idempotent");
            call([&](char **error) { return cbt_engine_save(tracked.get(), error); });
            tracked.reset();
            failure = nullptr;
            tracked = Engine(cbt_engine_create_configured((root / "tracker-profile").c_str(),
                R"({"autoAddTrackers":true,"defaultTrackers":"http://127.0.0.1:9/future"})", &failure), cbt_engine_destroy);
            require(tracked != nullptr, failure ? failure : "Tracker restoration failed");
            cbt_string_free(failure);
            require(trackerURLs(snapshot(tracked.get())) == expanded, "Tracker restoration lost appended entries or added new defaults to an existing task");
            tracked.reset();
            tracked = create(root / "tracker-magnet-profile");
            apply(tracked.get(), R"({"autoAddTrackers":true,"defaultTrackers":"http://127.0.0.1:9/future"})");
            const std::string trackedMagnet = "magnet:?xt=urn:btih:0123456789012345678901234567890123456789&tr=http%3A%2F%2F127.0.0.1%3A9%2Foriginal";
            call([&](char **error) { return cbt_engine_add(tracked.get(), trackedMagnet.c_str(), (root / "tracked-magnet").c_str(), 1, error); });
            require(trackerURLs(snapshot(tracked.get())) == std::set<std::string>{"http://127.0.0.1:9/original", "http://127.0.0.1:9/future"}, "Magnet tracker defaults were not appended");
            tracked.reset();
            tracked = create(root / "tracker-disabled-profile");
            apply(tracked.get(), R"({"autoAddTrackers":false,"defaultTrackers":"http://127.0.0.1:9/future"})");
            call([&](char **error) { return cbt_engine_add(tracked.get(), trackedMagnet.c_str(), (root / "tracked-disabled").c_str(), 1, error); });
            require(trackerURLs(snapshot(tracked.get())) == std::set<std::string>{"http://127.0.0.1:9/original"}, "Disabled automatic trackers modified a new task");
            for (const char *invalid : {R"({"autoAddTrackers":1})", R"({"defaultTrackers":[]})", R"({"defaultTrackers":"file:///tmp/tracker"})",
                R"({"defaultTrackers":"http://127.0.0.1:0/announce"})", R"({"defaultTrackers":"http://127.0.0.1:65536/announce"})",
                R"({"defaultTrackers":"http://127.0.0.1:abc/announce"})", R"({"defaultTrackers":"http:///announce"})",
                R"({"defaultTrackers":"http://127.0.0.1/a b"})", R"({"defaultTrackers":"http://127.0.0.1/\u0000announce"})"})
            {
                failure = nullptr;
                require(cbt_engine_apply_settings(tracked.get(), invalid, &failure) == 0, "Malformed tracker settings accepted");
                cbt_string_free(failure);
            }
            require(settings(tracked.get()).get<std::string>("defaultTrackers") == "http://127.0.0.1:9/future", "Rejected Tracker settings mutated saved configuration");
        }
        Engine seed = create(root / "seed-profile");
        Engine download = create(root / "download-profile");
        apply(download.get(), R"({"downloadLimitKB":128,"uploadLimitKB":64,"maxConnections":32,
            "maxConnectionsPerTorrent":8,"uploadSlots":4,"queueEnabled":false,"maxActiveDownloads":2,
            "maxActiveUploads":3,"maxActiveTorrents":4,"enableDHT":true,"enableLSD":true,
            "enableUPnP":true,"enableNATPMP":true,"enablePeX":false,"transportMode":1,
            "encryptionMode":1,"sequentialDownloads":true,"proxyType":1,"proxyHost":"127.0.0.1","proxyPort":1080})");
        const auto applied = settings(download.get());
        require(applied.get<int>("effective.downloadRateLimit") == 128 * 1024, "Download rate setting not applied");
        require(applied.get<int>("effective.uploadRateLimit") == 64 * 1024, "Upload rate setting not applied");
        require(applied.get<int>("effective.connectionsLimit") == 32, "Connection cap not applied");
        require(applied.get<int>("effective.uploadSlots") == 4, "Upload slots not applied");
        require(applied.get<int>("effective.activeDownloads") == -1, "Disabled queue still limits downloads");
        require(applied.get<bool>("effective.incomingTCP") && !applied.get<bool>("effective.incomingUTP"), "Transport mode not applied");
        require(applied.get<int>("effective.encryptionPolicy") == 0, "Required encryption not applied");
        require(!applied.get<bool>("effective.enableDHT") && !applied.get<bool>("effective.enableLSD")
            && !applied.get<bool>("effective.enableUPnP") && !applied.get<bool>("effective.enableNATPMP")
            && applied.get<int>("effective.proxyType") == 0
            && applied.get<std::string>("effective.listenInterfaces") == "127.0.0.1:0",
            "Settings bypassed loopback-only test isolation");
        char *settingsError = nullptr;
        require(cbt_engine_apply_settings(download.get(), R"({"downloadLimitKB":7,"listenPort":65536})", &settingsError) == 0,
            "Invalid settings were accepted");
        require(settingsError != nullptr, "Settings rejection omitted its reason");
        cbt_string_free(settingsError);
        require(settings(download.get()).get<int>("effective.downloadRateLimit") == 128 * 1024,
            "Invalid settings partially changed the engine");
        for (const char *invalid : {R"({"queueEnabled":"true"})", R"({"maxConnectionsPerTorrent":1})",
            R"({"proxyType":1,"proxyHost":"https://example.invalid"})", R"({"seedRatioLimit":-1})"})
        {
            settingsError = nullptr;
            require(cbt_engine_apply_settings(download.get(), invalid, &settingsError) == 0, "Malformed settings were accepted");
            cbt_string_free(settingsError);
        }
        apply(download.get(), R"({"downloadLimitKB":0,"uploadLimitKB":0,"proxyType":0})");
        call([&](char **error) { return cbt_engine_add(seed.get(), torrentPath.c_str(), (root / "seed").c_str(), 0, error); });
        const auto seedState = waitFor(seed.get(), [](const pt::ptree &state)
        {
            return firstTorrent(state).get<std::string>("state") == "seeding" && state.get<int>("listenPort") > 0;
        });
        const int seedPort = seedState.get<int>("listenPort");
        const auto params = lt::load_torrent_file(torrentPath.string());
        // v1-only magnet for a hybrid torrent exercises stable IDs after metadata arrives.
        const std::string magnet = std::regex_replace(lt::make_magnet_uri(params), std::regex("&xt=urn:btmh:[^&]*"), "");
        call([&](char **error) { return cbt_engine_add(download.get(), magnet.c_str(), (root / "download").c_str(), 0, error); });
        const std::string id = firstTorrent(snapshot(download.get())).get<std::string>("id");
        const auto taskSettings = settings(download.get()).get_child("torrents").front().second;
        require(taskSettings.get<bool>("sequentialDownloads") && !taskSettings.get<bool>("enablePeX")
            && !taskSettings.get<bool>("autoManaged") && taskSettings.get<int>("maxConnections") == 8,
            "New torrent did not receive global torrent settings");
        int attempt = 0;
        const auto completed = waitFor(download.get(), [&](const pt::ptree &state)
        {
            if (++attempt % 10 == 1)
                call([&](char **error) { return cbt_engine_connect_peer(download.get(), id.c_str(), "127.0.0.1", seedPort, error); });
            return firstTorrent(state).get<std::string>("state") == "seeding";
        }, 45s);
        require(firstTorrent(completed).get<std::string>("id") == id, "Torrent ID changed after metadata acquisition");
        require(firstTorrent(completed).get<int64_t>("downloaded") == static_cast<int64_t>(payload.size()), "Downloaded byte count mismatch");
        waitFor(download.get(), [&](const pt::ptree &state)
        {
            return state.get<int64_t>("totalDownloaded") >= static_cast<int64_t>(payload.size());
        });
        call([&](char **error) { return cbt_engine_pause(download.get(), id.c_str(), error); });
        call([&](char **error) { return cbt_engine_set_file_priority(download.get(), id.c_str(), 0, 7, error); });
        apply(download.get(), R"({"queueEnabled":true,"maxActiveDownloads":2,"maxActiveUploads":3,"maxActiveTorrents":4})");
        require(firstTorrent(snapshot(download.get())).get<std::string>("state") == "paused", "Changing queue settings resumed an explicitly paused task");
        require(settings(download.get()).get<int>("effective.activeDownloads") == 2, "Enabled queue limit not applied");
        apply(download.get(), R"({"queueEnabled":false})");
        require(firstTorrent(snapshot(download.get())).get<std::string>("state") == "paused", "Disabling queue resumed an explicitly paused task");
        call([&](char **error) { return cbt_engine_save(download.get(), error); });
        download.reset();
        require(readFile(root / "download/payload.bin") == payload, "Downloaded payload differs from the seed");
        char *creationError = nullptr;
        download = Engine(cbt_engine_create_configured((root / "download-profile").c_str(),
            R"({"queueEnabled":false,"enablePeX":false,"sequentialDownloads":true,"maxConnectionsPerTorrent":8,"downloadLimitKB":22})",
            &creationError), cbt_engine_destroy);
        require(download != nullptr, creationError ? creationError : "Configured session creation failed");
        cbt_string_free(creationError);
        const auto startupSettings = settings(download.get());
        require(startupSettings.get<int>("effective.downloadRateLimit") == 22 * 1024, "Startup rate limit was not applied");
        require(startupSettings.get_child("torrents").front().second.get<bool>("sequentialDownloads")
            && !startupSettings.get_child("torrents").front().second.get<bool>("enablePeX"), "Restored torrent did not receive startup settings");
        const auto restored = waitFor(download.get(), [](const pt::ptree &state)
        {
            return firstTorrent(state).get<std::string>("state") == "paused";
        });
        require(firstTorrent(restored).get<std::string>("id") == id, "Restored torrent ID changed");
        require(restored.get<int64_t>("totalDownloaded") == 0, "New session inherited previous session traffic");
        require(firstTorrent(restored).get_child("files").front().second.get<int>("priority") == 7, "File priority was not restored");
        char *error = nullptr;
        require(cbt_engine_add(download.get(), torrentPath.c_str(), (root / "download").c_str(), 0, &error) == 0, "Duplicate torrent was accepted");
        require(error != nullptr, "Duplicate torrent failure was not explained");
        cbt_string_free(error);
        call([&](char **failure) { return cbt_engine_resume(download.get(), id.c_str(), failure); });
        waitFor(download.get(), [](const pt::ptree &state) { return firstTorrent(state).get<std::string>("state") == "seeding"; });
        call([&](char **failure) { return cbt_engine_remove(download.get(), id.c_str(), 0, failure); });
        call([&](char **failure) { return cbt_engine_save(download.get(), failure); });
        download.reset();
        download = create(root / "download-profile");
        require(snapshot(download.get()).get_child("torrents").empty(), "Removed torrent returned after restart");
        require(readFile(root / "download/payload.bin") == payload, "Keep-files removal deleted data");
        error = nullptr;
        require(cbt_engine_add(download.get(), "magnet:?xt=urn:btih:not-a-valid-hash", (root / "download").c_str(), 0, &error) == 0,
            "Invalid magnet was accepted");
        require(error != nullptr, "Invalid magnet failure was not explained");
        cbt_string_free(error);
        require(snapshot(download.get()).get_child("torrents").empty(), "Invalid magnet created a task");
        apply(download.get(), R"({"preallocateFiles":true,"sequentialDownloads":true})");
        call([&](char **failure) { return cbt_engine_add(download.get(), torrentPath.c_str(), (root / "download").c_str(), 1, failure); });
        require(settings(download.get()).get_child("torrents").front().second.get<bool>("preallocateFiles"), "New torrent did not preallocate files");
        const std::string deletionID = firstTorrent(snapshot(download.get())).get<std::string>("id");
        call([&](char **failure) { return cbt_engine_remove(download.get(), deletionID.c_str(), 1, failure); });
        waitFor(download.get(), [&](const pt::ptree &state)
        {
            return state.get_child("torrents").empty() && !fs::exists(root / "download/payload.bin");
        });
        call([&](char **failure) { return cbt_engine_save(download.get(), failure); });
        download.reset();
        download = create(root / "download-profile");
        require(snapshot(download.get()).get_child("torrents").empty(), "Deleted torrent returned after restart");
        waitFor(seed.get(), [&](const pt::ptree &state)
        {
            return state.get<int64_t>("totalUploaded") >= static_cast<int64_t>(payload.size());
        });
        apply(seed.get(), R"({"seedRatioLimit":0.5})");
        waitFor(seed.get(), [](const pt::ptree &state) { return firstTorrent(state).get<std::string>("state") == "paused"; });
        call([&](char **failure) { return cbt_engine_save(seed.get(), failure); });
        const std::string seedID = firstTorrent(seedState).get<std::string>("id");
        const fs::path persistedResume = root / "seed-profile/ResumeData" / (seedID + ".fastresume");
        fs::create_directories(root / "recovered-profile/ResumeData");
        fs::copy_file(persistedResume, root / "recovered-profile/ResumeData" / persistedResume.filename());
        call([&](char **failure) { return cbt_engine_remove(seed.get(), seedID.c_str(), 0, failure); });
        const auto removedSeed = waitFor(seed.get(), [](const pt::ptree &state) { return state.get_child("torrents").empty(); });
        require(removedSeed.get<int64_t>("totalUploaded") >= static_cast<int64_t>(payload.size()), "Removing task reset session traffic counters");
        seed.reset();
        seed = create(root / "recovered-profile");
        require(firstTorrent(snapshot(seed.get())).get<std::string>("state") == "paused", "Seeding-limit stop decision was not persisted");
        require(snapshot(seed.get()).get<int64_t>("totalUploaded") == 0, "Restarted session inherited old traffic counters");
        seed.reset();

        // Restore accumulated completed-task time instead of making the test sleep a minute.
        // finished_time includes selected-file completion, matching the UI's seeding state.
        const fs::path recoveryResume = root / "recovered-profile/ResumeData" / persistedResume.filename();
        const std::string resumeBytes = readFile(recoveryResume);
        lt::error_code resumeError;
        auto resumeParams = lt::read_resume_data(lt::span<char const>(resumeBytes.data(), resumeBytes.size()), resumeError);
        require(!resumeError, "Could not decode saved task fixture");
        resumeParams.finished_time = 120;
        resumeParams.seeding_time = 0;
        resumeParams.flags &= ~lt::torrent_flags::paused;
        resumeParams.flags |= lt::torrent_flags::auto_managed;
        const auto timedResume = lt::write_resume_data_buf(resumeParams);
        {
            std::ofstream output(recoveryResume, std::ios::binary | std::ios::trunc);
            output.write(timedResume.data(), timedResume.size());
        }
        creationError = nullptr;
        seed = Engine(cbt_engine_create_configured((root / "recovered-profile").c_str(),
            R"({"seedTimeLimitMinutes":1})", &creationError), cbt_engine_destroy);
        require(seed != nullptr, creationError ? creationError : "Timed session creation failed");
        cbt_string_free(creationError);
        waitFor(seed.get(), [](const pt::ptree &state) { return firstTorrent(state).get<std::string>("state") == "paused"; });
        download.reset();
        seed.reset();
        fs::remove_all(root);
        std::cout << "PASS: loopback hybrid magnet metadata and payload transfer; stable IDs; pause/priority resume persistence; duplicate and invalid magnet rejection; resume; keep-files and delete-files removal survive restart; cumulative session traffic; validated settings apply/readback; startup settings; paused-task preservation; seeding ratio/time limits; tracker validation, automatic append, manual append, de-duplication and restart persistence\n";
        return 0;
    }
    catch (const std::exception &error)
    {
        std::cerr << "FAIL: " << error.what() << "\nArtifacts: " << root << '\n';
        return 1;
    }
}
