# CryoSoOp — C++ P-band SoOp radiometer data-acquisition binary for the Brundage B210 system.
#
# Build layout:
#   * cryosoop_common — static lib from src/common/*.cpp. UHD-FREE by construction (nothing under
#                       src/common includes UHD), so it builds anywhere yaml-cpp is available.
#                       This is the only target this CMake file *requires* to exist.
#   * cryosoop_device — static lib from src/device/*.cpp. Links UHD. Built only if src/device/
#                       exists. The radiometer is RX-only and has no local GPIO (cal-state GPIO
#                       lives on the BeagleBone behind state_cmd hooks), so no local-GPIO library
#                       dependency.
#   * cryosoop        — executable from src/main.cpp + radiometer_driver.cpp. Built only if
#                       src/main.cpp exists.
#   * cryosoop_tests  — UHD-free check binary from tests/*.cpp (timestamp/summary contracts).
#                       Built whenever tests/ exists, including under CRYOSOOP_COMMON_ONLY;
#                       run via ctest or directly.
#
# Options:
#   CRYOSOOP_COMMON_ONLY=ON  skip UHD entirely and build only cryosoop_common. Use this for the
#                            MSVC logic-compile check (no UHD on Windows; the real target is the Pi).

cmake_minimum_required(VERSION 3.15)
project(CryoSoOp LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# ---------------------------------------------------------------- options
option(CRYOSOOP_COMMON_ONLY "Build only the UHD-free common lib (skip UHD/device/exe)" OFF)

# ---------------------------------------------------------------- dependencies
# yaml-cpp is always required (cryosoop_common parses YAML). Normalize the imported-target name
# across yaml-cpp packaging variants.
find_package(yaml-cpp REQUIRED)
if(TARGET yaml-cpp::yaml-cpp)
    set(CRYOSOOP_YAMLCPP yaml-cpp::yaml-cpp)
elseif(TARGET yaml-cpp)
    set(CRYOSOOP_YAMLCPP yaml-cpp)
else()
    set(CRYOSOOP_YAMLCPP ${YAML_CPP_LIBRARIES})
endif()

# UHD is found only when we actually intend to build UHD-dependent targets. Any version is
# accepted (no version constraint). It is linked ONLY to device/driver/executable targets — never
# to cryosoop_common.
if(NOT CRYOSOOP_COMMON_ONLY)
    find_package(UHD REQUIRED)
endif()

find_package(Threads REQUIRED)

# ---------------------------------------------------------------- cryosoop_common (always)
file(GLOB CRYOSOOP_COMMON_SOURCES CONFIGURE_DEPENDS
     "${CMAKE_CURRENT_SOURCE_DIR}/src/common/*.cpp")

add_library(cryosoop_common STATIC ${CRYOSOOP_COMMON_SOURCES})
target_include_directories(cryosoop_common PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/common")
if(DEFINED YAML_CPP_INCLUDE_DIR)
    target_include_directories(cryosoop_common PUBLIC ${YAML_CPP_INCLUDE_DIR})
endif()
target_link_libraries(cryosoop_common PUBLIC ${CRYOSOOP_YAMLCPP} Threads::Threads)

# Portable-ish warning flags; harmless if the compiler ignores some.
if(MSVC)
    target_compile_options(cryosoop_common PRIVATE /W3)
else()
    target_compile_options(cryosoop_common PRIVATE -Wall -Wextra)
endif()

# ---------------------------------------------------------------- cryosoop_device (if present)
# UHD-dependent device layer. Only wire it up once its sources exist and we are not COMMON_ONLY.
set(CRYOSOOP_DEVICE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/src/device")
if(NOT CRYOSOOP_COMMON_ONLY AND EXISTS "${CRYOSOOP_DEVICE_DIR}")
    file(GLOB CRYOSOOP_DEVICE_SOURCES CONFIGURE_DEPENDS "${CRYOSOOP_DEVICE_DIR}/*.cpp")
    if(CRYOSOOP_DEVICE_SOURCES)
        add_library(cryosoop_device STATIC ${CRYOSOOP_DEVICE_SOURCES})
        target_link_libraries(cryosoop_device PUBLIC cryosoop_common ${UHD_LIBRARIES})
        target_include_directories(cryosoop_device PUBLIC ${UHD_INCLUDE_DIRS})
    endif()
endif()

# ---------------------------------------------------------------- cryosoop executable (if present)
# Guarded so the build works before main.cpp lands.
if(NOT CRYOSOOP_COMMON_ONLY AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/src/main.cpp")
    set(CRYOSOOP_EXE_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/src/main.cpp")
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/src/radiometer_driver.cpp")
        list(APPEND CRYOSOOP_EXE_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/src/radiometer_driver.cpp")
    endif()

    add_executable(cryosoop ${CRYOSOOP_EXE_SOURCES})
    target_include_directories(cryosoop PRIVATE ${UHD_INCLUDE_DIRS})
    # Link the device lib first (it PUBLIC-propagates cryosoop_common + UHD) so the static link
    # order is correct on GNU ld (dependents before dependencies). yaml-cpp + Threads come in
    # transitively via cryosoop_common, but are named explicitly so the exe still links cleanly if
    # cryosoop_device is ever absent.
    if(TARGET cryosoop_device)
        target_link_libraries(cryosoop PRIVATE cryosoop_device)
    endif()
    target_link_libraries(cryosoop PRIVATE
        cryosoop_common ${UHD_LIBRARIES} ${CRYOSOOP_YAMLCPP} Threads::Threads)
else()
    message(STATUS "CryoSoOp: src/main.cpp not present (or COMMON_ONLY) — building cryosoop_common only.")
endif()

# ---------------------------------------------------------------- cryosoop_tests (if present)
# UHD-free contract checks (UTC timestamp helpers, summary.json emission). Deliberately built in
# every configuration — including CRYOSOOP_COMMON_ONLY — so the MSVC compile-check host can run
# them, not just the Pi.
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_time_stamps.cpp")
    enable_testing()
    add_executable(cryosoop_tests "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_time_stamps.cpp")
    target_link_libraries(cryosoop_tests PRIVATE cryosoop_common)
    add_test(NAME time_stamps COMMAND cryosoop_tests)
endif()
