#pragma once

#include <string>
#include <vector>
#include <libtorrent/settings_pack.hpp>
#import <Foundation/Foundation.h>

namespace NativeEngine
{
    NSDictionary *defaultConfiguration();
    NSDictionary *validatedConfiguration(NSDictionary *current, const char *json);
    std::vector<std::string> defaultTrackers(NSDictionary *configuration);
    libtorrent::settings_pack configurationSettings(NSDictionary *next);
}
