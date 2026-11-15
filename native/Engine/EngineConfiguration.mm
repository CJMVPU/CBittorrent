#include "EngineConfiguration.h"

#include <cmath>
#include <cstdlib>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>


#include <libtorrent/alert.hpp>

#include "EngineSupport.h"

namespace lt = libtorrent;
namespace fs = std::filesystem;

namespace NativeEngine
{
    NSDictionary *defaultConfiguration()
    {
        return @{@"downloadLimitKB": @0, @"uploadLimitKB": @0, @"listenPort": @0,
            @"enableUPnP": @YES, @"enableNATPMP": @YES, @"enableDHT": @YES, @"enablePeX": @YES, @"enableLSD": @YES,
            @"transportMode": @0, @"encryptionMode": @0, @"maxConnections": @200,
            @"maxConnectionsPerTorrent": @100, @"uploadSlots": @8, @"queueEnabled": @YES,
            @"maxActiveDownloads": @3, @"maxActiveUploads": @5, @"maxActiveTorrents": @8,
            @"seedRatioLimit": @0, @"seedTimeLimitMinutes": @0,
            @"sequentialDownloads": @NO, @"preallocateFiles": @NO,
            @"proxyType": @0, @"proxyHost": @"", @"proxyPort": @1080,
            @"proxyPeers": @YES, @"proxyTrackers": @YES,
            @"autoAddTrackers": @NO, @"defaultTrackers": @""};
    }

    int integerSetting(NSDictionary *values, NSString *key, int minimum, int maximum)
    {
        id value = values[key];
        if (![value isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID())
            throw std::invalid_argument(std::string(key.UTF8String) + " must be an integer");
        const double number = [value doubleValue];
        if (!std::isfinite(number) || std::floor(number) != number || number < minimum || number > maximum)
            throw std::invalid_argument(std::string(key.UTF8String) + " is out of range");
        return static_cast<int>(number);
    }

    bool booleanSetting(NSDictionary *values, NSString *key)
    {
        id value = values[key];
        if (![value isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID())
            throw std::invalid_argument(std::string(key.UTF8String) + " must be true or false");
        return [value boolValue];
    }

    NSDictionary *validatedConfiguration(NSDictionary *current, const char *json)
    {
        const std::string input = requiredString(json, "Settings JSON");
        NSData *data = [NSData dataWithBytes:input.data() length:input.size()];
        NSError *error = nil;
        id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (![decoded isKindOfClass:[NSDictionary class]])
            throw std::invalid_argument("Settings must be a JSON object");
        NSMutableDictionary *result = [current mutableCopy];
        // App-only preferences may share the payload; only engine keys cross this boundary.
        for (NSString *key in current)
        {
            if (decoded[key] != nil)
                result[key] = decoded[key];
        }
        for (NSString *key in @[@"enableUPnP", @"enableNATPMP", @"enableDHT", @"enablePeX", @"enableLSD",
            @"queueEnabled", @"sequentialDownloads", @"preallocateFiles", @"proxyPeers", @"proxyTrackers", @"autoAddTrackers"])
            booleanSetting(result, key);
        integerSetting(result, @"downloadLimitKB", 0, std::numeric_limits<int>::max() / 1024);
        integerSetting(result, @"uploadLimitKB", 0, std::numeric_limits<int>::max() / 1024);
        integerSetting(result, @"listenPort", 0, 65535);
        integerSetting(result, @"transportMode", 0, 2);
        integerSetting(result, @"encryptionMode", 0, 2);
        for (NSString *key in @[@"maxConnections", @"maxConnectionsPerTorrent"])
        {
            if (integerSetting(result, key, 0, std::numeric_limits<int>::max()) == 1)
                throw std::invalid_argument(std::string(key.UTF8String) + " must be zero or at least two");
        }
        integerSetting(result, @"uploadSlots", 0, std::numeric_limits<int>::max());
        for (NSString *key in @[@"maxActiveDownloads", @"maxActiveUploads", @"maxActiveTorrents"])
            integerSetting(result, key, 1, std::numeric_limits<int>::max());
        integerSetting(result, @"seedTimeLimitMinutes", 0, std::numeric_limits<int>::max() / 60);
        id ratio = result[@"seedRatioLimit"];
        if (![ratio isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)ratio) == CFBooleanGetTypeID()
            || !std::isfinite([ratio doubleValue]) || [ratio doubleValue] < 0 || [ratio doubleValue] > 10000)
            throw std::invalid_argument("seedRatioLimit must be between zero and 10000");
        const int proxyType = integerSetting(result, @"proxyType", 0, 2);
        integerSetting(result, @"proxyPort", proxyType ? 1 : 0, 65535);
        id host = result[@"proxyHost"];
        if (![host isKindOfClass:[NSString class]])
            throw std::invalid_argument("proxyHost must be text");
        NSString *trimmed = [host stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (proxyType && (trimmed.length == 0 || [trimmed rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound
            || [trimmed containsString:@"://"] || [trimmed containsString:@"/"]
            || [trimmed rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound))
            throw std::invalid_argument("Proxy host must be a hostname or IP address without a URL scheme or path");
        result[@"proxyHost"] = trimmed;
        id trackerText = result[@"defaultTrackers"];
        if (![trackerText isKindOfClass:[NSString class]])
            throw std::invalid_argument("defaultTrackers must be text");
        NSMutableArray<NSString *> *trackers = [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        NSMutableCharacterSet *forbidden = [[NSCharacterSet whitespaceAndNewlineCharacterSet] mutableCopy];
        [forbidden formUnionWithCharacterSet:[NSCharacterSet controlCharacterSet]];
        for (NSString *line in [trackerText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]])
        {
            NSString *tracker = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (tracker.length == 0)
                continue;
            NSURLComponents *url = [NSURLComponents componentsWithString:tracker];
            if ([tracker rangeOfCharacterFromSet:forbidden].location != NSNotFound || !url.URL || !url.host.length
                || ![@[@"http", @"https", @"udp"] containsObject:url.scheme.lowercaseString]
                || (url.port && (url.port.integerValue < 1 || url.port.integerValue > 65535)))
                throw std::invalid_argument("Tracker URLs must use http, https or udp with a host and valid port");
            if (![seen containsObject:tracker])
            {
                [seen addObject:tracker];
                [trackers addObject:tracker];
            }
        }
        result[@"defaultTrackers"] = [trackers componentsJoinedByString:@"\n"];
        return [result copy];
    }

    std::vector<std::string> defaultTrackers(NSDictionary *configuration)
    {
        std::vector<std::string> result;
        for (NSString *url in [configuration[@"defaultTrackers"] componentsSeparatedByString:@"\n"])
        {
            if (url.length)
                result.emplace_back(url.UTF8String);
        }
        return result;
    }

    lt::settings_pack initialSettings()
    {
        lt::settings_pack settings;
        settings.set_str(lt::settings_pack::user_agent, "CBittorrent/0.6.0");
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

    lt::settings_pack configurationSettings(NSDictionary *next)
    {
        lt::settings_pack settings = initialSettings();
        const bool local = std::getenv("CBT_ENGINE_LOCAL_ONLY") != nullptr;
        const int port = [next[@"listenPort"] intValue];
        settings.set_str(lt::settings_pack::listen_interfaces, local ? "127.0.0.1:0"
            : "0.0.0.0:" + std::to_string(port) + ",[::]:" + std::to_string(port));
        settings.set_bool(lt::settings_pack::enable_upnp, !local && [next[@"enableUPnP"] boolValue]);
        settings.set_bool(lt::settings_pack::enable_natpmp, !local && [next[@"enableNATPMP"] boolValue]);
        settings.set_bool(lt::settings_pack::enable_dht, !local && [next[@"enableDHT"] boolValue]);
        settings.set_bool(lt::settings_pack::enable_lsd, !local && [next[@"enableLSD"] boolValue]);
        const int transport = [next[@"transportMode"] intValue];
        settings.set_bool(lt::settings_pack::enable_incoming_tcp, transport != 2);
        settings.set_bool(lt::settings_pack::enable_outgoing_tcp, transport != 2);
        settings.set_bool(lt::settings_pack::enable_incoming_utp, transport != 1);
        settings.set_bool(lt::settings_pack::enable_outgoing_utp, transport != 1);
        const int encryption = [next[@"encryptionMode"] intValue];
        const int policy = encryption == 1 ? lt::settings_pack::pe_forced : encryption == 2 ? lt::settings_pack::pe_disabled : lt::settings_pack::pe_enabled;
        settings.set_int(lt::settings_pack::in_enc_policy, policy);
        settings.set_int(lt::settings_pack::out_enc_policy, policy);
        settings.set_int(lt::settings_pack::allowed_enc_level, encryption == 1 ? lt::settings_pack::pe_rc4 : lt::settings_pack::pe_both);
        settings.set_bool(lt::settings_pack::prefer_rc4, encryption != 2);
        settings.set_int(lt::settings_pack::download_rate_limit, [next[@"downloadLimitKB"] intValue] * 1024);
        settings.set_int(lt::settings_pack::upload_rate_limit, [next[@"uploadLimitKB"] intValue] * 1024);
        const int connections = [next[@"maxConnections"] intValue];
        settings.set_int(lt::settings_pack::connections_limit, connections == 0 ? std::numeric_limits<int>::max() : connections);
        const int slots = [next[@"uploadSlots"] intValue];
        settings.set_int(lt::settings_pack::unchoke_slots_limit, slots == 0 ? -1 : slots);
        settings.set_int(lt::settings_pack::choking_algorithm, lt::settings_pack::fixed_slots_choker);
        const bool queue = [next[@"queueEnabled"] boolValue];
        settings.set_int(lt::settings_pack::active_downloads, queue ? [next[@"maxActiveDownloads"] intValue] : -1);
        settings.set_int(lt::settings_pack::active_seeds, queue ? [next[@"maxActiveUploads"] intValue] : -1);
        settings.set_int(lt::settings_pack::active_limit, queue ? [next[@"maxActiveTorrents"] intValue] : -1);
        // Our explicit pause policy persists the stop decision. Disable libtorrent's
        // implicit seed queue limits so its defaults cannot silently stop tasks sooner.
        settings.set_int(lt::settings_pack::share_ratio_limit, std::numeric_limits<int>::max());
        settings.set_int(lt::settings_pack::seed_time_ratio_limit, std::numeric_limits<int>::max());
        settings.set_int(lt::settings_pack::seed_time_limit, std::numeric_limits<int>::max());
        const int proxy = local ? 0 : [next[@"proxyType"] intValue];
        settings.set_int(lt::settings_pack::proxy_type, proxy == 1 ? lt::settings_pack::socks5 : proxy == 2 ? lt::settings_pack::http : lt::settings_pack::none);
        settings.set_str(lt::settings_pack::proxy_hostname, proxy ? std::string([next[@"proxyHost"] UTF8String]) : "");
        settings.set_int(lt::settings_pack::proxy_port, [next[@"proxyPort"] intValue]);
        settings.set_bool(lt::settings_pack::proxy_peer_connections, proxy && [next[@"proxyPeers"] boolValue]);
        settings.set_bool(lt::settings_pack::proxy_tracker_connections, proxy && [next[@"proxyTrackers"] boolValue]);
        settings.set_bool(lt::settings_pack::proxy_hostnames, proxy != 0);
        return settings;
    }

}
