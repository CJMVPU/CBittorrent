cmake_minimum_required(VERSION 3.21)

project(CBittorrent VERSION 0.1.0 LANGUAGES NONE)

if(NOT CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin" OR
   NOT CMAKE_HOST_SYSTEM_PROCESSOR STREQUAL "arm64")
    message(FATAL_ERROR "CBittorrent requires an Apple Silicon Mac and the macOS 27+ SDK.")
endif()

# The native target intentionally does not include the legacy Qt build modules.
# Compilation, dependency bundling, signing and the Qt-free audit share one route.
set(CBITTORRENT_CONFIGURATION "release" CACHE STRING "Native build configuration: debug or release")
set_property(CACHE CBITTORRENT_CONFIGURATION PROPERTY STRINGS debug release)
add_custom_target(CBittorrent ALL
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/native/build.sh"
        --output "${CMAKE_CURRENT_BINARY_DIR}/native"
        --configuration "${CBITTORRENT_CONFIGURATION}"
    BYPRODUCTS "${CMAKE_CURRENT_BINARY_DIR}/native/CBittorrent.app/Contents/MacOS/CBittorrent"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    VERBATIM
)

include(CTest)
if(BUILD_TESTING)
    add_test(NAME native_engine
        COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/native/tests/run.sh"
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    )
    set_tests_properties(native_engine PROPERTIES TIMEOUT 180)
endif()
