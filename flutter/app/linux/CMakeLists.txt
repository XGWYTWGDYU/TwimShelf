# Project-level configuration.
cmake_minimum_required(VERSION 3.16)
project(runner LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "twimshelf")
# name, application id, "open with": from config.yaml (scripts/apply.py)
include("${CMAKE_CURRENT_SOURCE_DIR}/identity.cmake")
# The icon name stays stable across release and debug builds.
set(APP_ICON_NAME "${TL_APPLICATION_ID}")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
  set(APPLICATION_ID "${TL_APPLICATION_ID}.debug")
  set(APP_DISPLAY_NAME "${TL_APP_NAME} Debug")
else()
  set(APPLICATION_ID "${TL_APPLICATION_ID}")
  set(APP_DISPLAY_NAME "${TL_APP_NAME}")
endif()

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
# Before the plugins: a first configure that fails in one of them would otherwise leave /usr/local
# in the cache for good.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()
include(flutter/generated_plugins.cmake)


# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# media_kit uses system libmpv by default. Include it and codecs in the bundle.
find_library(TL_LIBMPV NAMES mpv libmpv.so.2 libmpv.so.1)
if(NOT TL_LIBMPV)
  message(FATAL_ERROR "Install the libmpv development/runtime packages before building video support")
endif()
if(TARGET MIMALLOC_TARGET)
  add_dependencies(${BINARY_NAME} MIMALLOC_TARGET)
endif()
if(MIMALLOC_LIB)
  target_link_libraries(${BINARY_NAME} PRIVATE ${MIMALLOC_LIB})
endif()
configure_file(cmake/bundle_video.cmake.in ${CMAKE_CURRENT_BINARY_DIR}/bundle_video.cmake @ONLY)
install(SCRIPT ${CMAKE_CURRENT_BINARY_DIR}/bundle_video.cmake COMPONENT Runtime)

# Catalog-derived desktop registration, installed alongside the relocatable app.
include("${FLUTTER_MANAGED_DIR}/ephemeral/generated_config.cmake")
get_filename_component(TL_FLUTTER_ROOT "${FLUTTER_ROOT}" ABSOLUTE)
set(TL_DESKTOP_FILE "${CMAKE_CURRENT_BINARY_DIR}/${APPLICATION_ID}.desktop")
add_custom_command(OUTPUT "${TL_DESKTOP_FILE}"
  COMMAND "${TL_FLUTTER_ROOT}/bin/dart" "${CMAKE_CURRENT_SOURCE_DIR}/../lib/platform/desktop_entry.dart"
    "${CMAKE_CURRENT_SOURCE_DIR}/../assets/l10n" "${TL_DESKTOP_FILE}" "${BINARY_NAME}" "${TL_APP_NAME}"
  COMMAND "${CMAKE_COMMAND}" "-DDESKTOP_FILE=${TL_DESKTOP_FILE}"
    "-DAPP_ID=${APPLICATION_ID}" "-DAPP_ICON=${APP_ICON_NAME}" "-DSHARE=${TL_SHARE_ENABLED}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/fix_desktop.cmake"
  DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/../lib/platform/desktop_entry.dart"
    "${CMAKE_CURRENT_SOURCE_DIR}/../assets/l10n/en.json"
    "${CMAKE_CURRENT_SOURCE_DIR}/../assets/l10n/ja.json"
    "${CMAKE_CURRENT_SOURCE_DIR}/../assets/l10n/zh-Hans.json"
    "${CMAKE_CURRENT_SOURCE_DIR}/../assets/l10n/zh-Hant.json"
    "${CMAKE_CURRENT_SOURCE_DIR}/cmake/fix_desktop.cmake"
  VERBATIM)
add_custom_target(desktop_entry ALL DEPENDS "${TL_DESKTOP_FILE}")
install(FILES "${TL_DESKTOP_FILE}" DESTINATION "${CMAKE_INSTALL_PREFIX}/share/applications" COMPONENT Runtime)

# Generate desktop icons and AppStream metadata in the build tree.
find_package(Python3 REQUIRED COMPONENTS Interpreter)
set(TL_DESKTOP_ASSETS "${CMAKE_CURRENT_BINARY_DIR}/desktop-assets")
file(GLOB TL_NATIVE_ICONS CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/../../../native/Resources/Assets.xcassets/AppIcon.appiconset/mac-*.png")
add_custom_command(OUTPUT "${TL_DESKTOP_ASSETS}/${APPLICATION_ID}.metainfo.xml"
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/../../../scripts/flutter/desktop_assets.py"
    "${TL_DESKTOP_ASSETS}" --app-id "${APPLICATION_ID}" --app-name "${TL_APP_NAME}" --icon-name "${APP_ICON_NAME}"
  DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/../../../scripts/flutter/desktop_assets.py"
    ${TL_NATIVE_ICONS}
    "${CMAKE_CURRENT_SOURCE_DIR}/../assets/l10n/en.json"
    "${CMAKE_CURRENT_SOURCE_DIR}/../assets/l10n/ja.json"
    "${CMAKE_CURRENT_SOURCE_DIR}/../assets/l10n/zh-Hans.json"
    "${CMAKE_CURRENT_SOURCE_DIR}/../assets/l10n/zh-Hant.json"
  VERBATIM)
add_custom_target(desktop_assets ALL DEPENDS "${TL_DESKTOP_ASSETS}/${APPLICATION_ID}.metainfo.xml")
install(DIRECTORY "${TL_DESKTOP_ASSETS}/icons/" DESTINATION "${CMAKE_INSTALL_PREFIX}/share/icons" COMPONENT Runtime)
install(FILES "${TL_DESKTOP_ASSETS}/${APPLICATION_ID}.metainfo.xml"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/share/metainfo" COMPONENT Runtime)
