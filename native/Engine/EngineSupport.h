#pragma once

#include <filesystem>
#include <string>
#include <vector>
#include <libtorrent/info_hash.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_status.hpp>
#import <Foundation/Foundation.h>

namespace NativeEngine
{
    char *copyString(const std::string &value);
    NSString *stringValue(const std::string &value);
    std::string requiredString(const char *value, const char *name);
    std::string hashString(const libtorrent::info_hash_t &hashes);
    void atomicWrite(const std::filesystem::path &path, const std::vector<char> &bytes);
    std::string stateName(const libtorrent::torrent_status &status);
}
