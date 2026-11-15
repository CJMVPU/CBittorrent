#include "CBTEngine.h"

#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <thread>

#include <boost/property_tree/json_parser.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/torrent_info.hpp>

namespace fs = std::filesystem;
namespace lt = libtorrent;
namespace pt = boost::property_tree;
using namespace std::chrono_literals;

namespace
{
    void require(bool value, const char *message)
    {
        if (!value) throw std::runtime_error(message);
    }

    template <typename F>
    void command(F action)
    {
        char *error = nullptr;
        const int result = action(&error);
        const std::string message = error ? error : "Upload comparison command failed";
        cbt_string_free(error);
        if (!result) throw std::runtime_error(message);
    }

    pt::ptree snapshot(CBTEngine *engine)
    {
        char *json = cbt_engine_summary_json(engine);
        require(json != nullptr, "Upload comparison snapshot failed");
        std::istringstream input(json);
        cbt_string_free(json);
        pt::ptree result;
        pt::read_json(input, result);
        return result;
    }
}

// Independent libtorrent receiver: no CBittorrent adapter or UI on the download
// side. Compare native and qBittorrent-style seed policies with identical data.
// This is a policy/transport comparison, not a qBittorrent binary benchmark.
void checkUploadInterop(const fs::path &root)
{
    for (const bool native : {true, false})
    {
        for (const bool utp : {false, true})
        {
            const std::string label = std::string(native ? "native" : "qbt-policy") + (utp ? "-utp" : "-tcp");
            const auto directory = root / label;
            fs::create_directories(directory / "seed");
            fs::create_directories(directory / "receive");
            const std::string payload(256 * 1024, 'U');
            std::ofstream(directory / "seed/upload.bin", std::ios::binary).write(payload.data(), payload.size());
            lt::create_torrent creator({lt::create_file_entry("upload.bin", payload.size())}, 16 * 1024);
            creator.set_priv(true);
            lt::set_piece_hashes(creator, (directory / "seed").string());
            std::vector<char> bytes;
            lt::bencode(std::back_inserter(bytes), creator.generate());
            const auto torrentPath = directory / "upload.torrent";
            std::ofstream(torrentPath, std::ios::binary).write(bytes.data(), bytes.size());
            lt::settings_pack settings;
            settings.set_str(lt::settings_pack::listen_interfaces, "127.0.0.1:0");
            settings.set_bool(lt::settings_pack::enable_dht, false);
            settings.set_bool(lt::settings_pack::enable_lsd, false);
            settings.set_bool(lt::settings_pack::enable_upnp, false);
            settings.set_bool(lt::settings_pack::enable_natpmp, false);
            settings.set_bool(lt::settings_pack::enable_incoming_tcp, !utp);
            settings.set_bool(lt::settings_pack::enable_outgoing_tcp, !utp);
            settings.set_bool(lt::settings_pack::enable_incoming_utp, utp);
            settings.set_bool(lt::settings_pack::enable_outgoing_utp, utp);
            // These settings match the repository's qBittorrent defaults.
            settings.set_int(lt::settings_pack::choking_algorithm, lt::settings_pack::fixed_slots_choker);
            settings.set_int(lt::settings_pack::seed_choking_algorithm, lt::settings_pack::fastest_upload);
            settings.set_int(lt::settings_pack::unchoke_slots_limit, 20);
            lt::session receiver(settings);
            auto receiveParams = lt::load_torrent_file(torrentPath.string());
            receiveParams.save_path = (directory / "receive").string();
            receiveParams.flags &= ~(lt::torrent_flags::paused | lt::torrent_flags::auto_managed);
            const auto receiving = receiver.add_torrent(receiveParams);
            std::unique_ptr<CBTEngine, decltype(&cbt_engine_destroy)> engine(nullptr, cbt_engine_destroy);
            std::unique_ptr<lt::session> reference;
            lt::torrent_handle referenceSeed;
            int port = 0;
            const auto deadline = std::chrono::steady_clock::now() + 25s;
            if (native)
            {
                char *error = nullptr;
                const std::string config = utp ? R"({"transportMode":2})" : R"({"transportMode":1})";
                engine.reset(cbt_engine_create_configured((directory / "profile").c_str(), config.c_str(), &error));
                const std::string message = error ? error : "Failed to create upload comparison engine";
                cbt_string_free(error);
                if (!engine) throw std::runtime_error(message);
                // Exercise the new preview/confirmation path with preexisting
                // complete data, including add-paused and resume behavior.
                char *preview = nullptr;
                command([&](char **failure) { return cbt_engine_prepare_metadata(engine.get(), torrentPath.c_str(), &preview, failure); });
                const std::string id(preview);
                cbt_string_free(preview);
                command([&](char **failure) { return cbt_engine_confirm_metadata(engine.get(), id.c_str(), (directory / "seed").c_str(), 1, failure); });
                const auto added = snapshot(engine.get()).get_child("torrents").front().second.get<std::string>("id");
                command([&](char **failure) { return cbt_engine_resume(engine.get(), added.c_str(), failure); });
                while (std::chrono::steady_clock::now() < deadline)
                {
                    const auto state = snapshot(engine.get());
                    if (state.get_child("torrents").front().second.get<std::string>("state") == "seeding")
                    {
                        port = state.get<int>("listenPort");
                        break;
                    }
                    std::this_thread::sleep_for(50ms);
                }
            }
            else
            {
                reference = std::make_unique<lt::session>(settings);
                auto seedParams = lt::load_torrent_file(torrentPath.string());
                seedParams.save_path = (directory / "seed").string();
                seedParams.flags &= ~(lt::torrent_flags::paused | lt::torrent_flags::auto_managed);
                seedParams.max_uploads = 4;
                referenceSeed = reference->add_torrent(seedParams);
                while (!referenceSeed.status().is_seeding && std::chrono::steady_clock::now() < deadline)
                    std::this_thread::sleep_for(50ms);
                port = reference->listen_port();
            }
            require(port > 0, "Upload comparison seed did not become ready");
            receiving.connect_peer({lt::make_address("127.0.0.1"), static_cast<unsigned short>(port)});
            while (!receiving.status().is_seeding && std::chrono::steady_clock::now() < deadline)
                std::this_thread::sleep_for(50ms);
            require(receiving.status().is_seeding, "Interested independent receiver received no complete upload");
            std::ifstream output(directory / "receive/upload.bin", std::ios::binary);
            const std::string received((std::istreambuf_iterator<char>(output)), std::istreambuf_iterator<char>());
            require(received == payload, "Upload comparison payload mismatch");
            int64_t uploaded = 0;
            // The receiver's disk completion and the sender's accounting tick
            // are asynchronous, including in an unwrapped libtorrent session.
            const auto accountingDeadline = std::chrono::steady_clock::now() + 5s;
            do
            {
                if (native)
                    uploaded = snapshot(engine.get()).get_child("torrents").front().second.get<int64_t>("uploaded");
                else
                    uploaded = referenceSeed.status().all_time_upload;
                if (uploaded >= static_cast<int64_t>(payload.size())) break;
                std::this_thread::sleep_for(50ms);
            } while (std::chrono::steady_clock::now() < accountingDeadline);
            require(uploaded >= static_cast<int64_t>(payload.size()), "Sender upload accounting did not record transfer");
            std::cout << "PASS: upload comparison " << label << ": received " << received.size()
                      << " bytes, sender recorded " << uploaded << " bytes\n";
        }
    }
}
