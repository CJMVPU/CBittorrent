#include "EngineSupport.h"

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <vector>

#include <sys/stat.h>
#include <unistd.h>



namespace lt = libtorrent;
namespace fs = std::filesystem;

namespace NativeEngine
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
