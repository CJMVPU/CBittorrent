#include "CBTEngine.h"

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <thread>

#include <boost/property_tree/json_parser.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/magnet_uri.hpp>

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
        Engine seed = create(root / "seed-profile");
        Engine download = create(root / "download-profile");
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
        call([&](char **error) { return cbt_engine_save(download.get(), error); });
        download.reset();
        require(readFile(root / "download/payload.bin") == payload, "Downloaded payload differs from the seed");
        download = create(root / "download-profile");
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
        call([&](char **failure) { return cbt_engine_add(download.get(), torrentPath.c_str(), (root / "download").c_str(), 1, failure); });
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
        const std::string seedID = firstTorrent(seedState).get<std::string>("id");
        call([&](char **failure) { return cbt_engine_remove(seed.get(), seedID.c_str(), 0, failure); });
        const auto removedSeed = waitFor(seed.get(), [](const pt::ptree &state) { return state.get_child("torrents").empty(); });
        require(removedSeed.get<int64_t>("totalUploaded") >= static_cast<int64_t>(payload.size()), "Removing task reset session traffic counters");
        download.reset();
        seed.reset();
        fs::remove_all(root);
        std::cout << "PASS: loopback hybrid magnet metadata and payload transfer; stable IDs; pause/priority resume persistence; duplicate and invalid magnet rejection; resume; keep-files and delete-files removal survive restart; cumulative session traffic\n";
        return 0;
    }
    catch (const std::exception &error)
    {
        std::cerr << "FAIL: " << error.what() << "\nArtifacts: " << root << '\n';
        return 1;
    }
}
