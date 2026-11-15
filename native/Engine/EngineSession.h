#pragma once

#include "CBTEngine.h"
#include <chrono>
#include <filesystem>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <vector>
#include <libtorrent/session.hpp>
#import <Foundation/Foundation.h>

namespace lt = libtorrent;
namespace fs = std::filesystem;

// Internal session aggregate. All access is guarded by the C facade mutex.
// Never import this header into Swift or presentation code.
struct CBTEngine
{
    CBTEngine(const fs::path &profile, NSDictionary *configured);
    lt::torrent_handle find(const char *id);
    std::string torrentID(const lt::torrent_handle &handle);
    void report(const std::string &message);
    void restore();
    void restoreStatistics();
    void saveStatistics();
    lt::torrent_flags_t policyFlags() const;
    int connectionLimit() const;
    void configureParameters(lt::add_torrent_params &params) const;
    void configureTorrent(const lt::torrent_handle &handle);
    void applyConfiguration(NSDictionary *next);
    void enforceSeedLimits();
    void processAlerts();
    void requestSave(const lt::torrent_handle &handle);
    void queueSave(const lt::torrent_handle &handle);
    void requestSaves();
    void save(bool all = true);

    std::mutex mutex;
    fs::path profilePath;
    fs::path resumePath;
    lt::session session;
    NSDictionary *configuration;
    std::set<lt::torrent_handle> pendingSaves;
    std::set<lt::torrent_handle> dirtyHandles;
    std::map<lt::torrent_handle, std::string> torrentIDs;
    std::map<std::string, lt::torrent_handle> handlesByID;
    std::set<lt::torrent_handle> removedHandles;
    std::vector<std::string> errors;
    int dhtNodes = 0;
    int64_t totalDownloaded = 0;
    int64_t totalUploaded = 0;
    int64_t historicalDownloaded = 0;
    int64_t historicalUploaded = 0;
    unsigned statisticsGeneration = 0;
    bool saveFailed = false;
    std::chrono::steady_clock::time_point lastSave = std::chrono::steady_clock::now();
    std::chrono::steady_clock::time_point lastDHT = std::chrono::steady_clock::now();
};
