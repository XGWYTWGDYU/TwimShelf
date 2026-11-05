# llama.cpp with a small C interface (tl_llama.cpp) for Dart's FFI. Used by the Android, Windows
# and Linux builds; the Apple builds run MLX instead (native/TLLocalAI).
#
# Backends are loaded at run time (GGML_BACKEND_DL): the CPU one in the variants for each
# instruction set, and Vulkan where the build has its SDK. A device without a working Vulkan
# driver simply runs on the CPU. The source is fetched once at configure time, pinned below
# (about 30 MB); point TL_LLAMA_SOURCE at a local checkout to build offline.
cmake_minimum_required(VERSION 3.21)
project(tl_llama LANGUAGES C CXX)

set(TL_LLAMA_TAG "v0.8.0" CACHE STRING "llama.cpp release tag")
set(TL_LLAMA_SOURCE "" CACHE PATH "a local llama.cpp checkout (instead of downloading)")
option(TL_LLAMA_VULKAN "build the Vulkan backend" ON)
option(TL_LLAMA_OPENCL "build the OpenCL backend (Adreno GPUs, on Android)" OFF)

set(BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL ON CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON ON CACHE BOOL "" FORCE)   # its tools (mtmd, the vision part) need it
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS ON CACHE BOOL "" FORCE)   # mtmd (the vision part) lives under tools/
set(LLAMA_CURL OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)        # binaries run on other machines than the builder
if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64|amd64")
  set(GGML_CPU_ALL_VARIANTS ON CACHE BOOL "" FORCE)
endif()
if(TL_LLAMA_VULKAN)
  # the NDK's shader compiler lies outside what its toolchain lets CMake search
  if(ANDROID AND NOT Vulkan_GLSLC_EXECUTABLE)
    file(GLOB TL_GLSLC "${ANDROID_NDK}/shader-tools/*/glslc*")
    if(TL_GLSLC)
      list(GET TL_GLSLC 0 TL_GLSLC)
      set(Vulkan_GLSLC_EXECUTABLE "${TL_GLSLC}" CACHE FILEPATH "" FORCE)
    endif()
  endif()
  find_package(Vulkan QUIET)
  if(Vulkan_FOUND OR ANDROID)
    set(GGML_VULKAN ON CACHE BOOL "" FORCE)
    # vulkan-shaders-gen passes paths to glslc unquoted, every shader fails on a path with a space,
    # and after 16 failures it waits forever at no CPU (llama.cpp b6500): say so instead
    if(CMAKE_BINARY_DIR MATCHES " ")
      message(FATAL_ERROR "tl_llama: the Vulkan backend cannot be built in a path with spaces: ${CMAKE_BINARY_DIR}. Set build.dir in config.yaml to one without.")
    endif()
  else()
    message(WARNING "tl_llama: no Vulkan SDK found; building the CPU backend only")
  endif()
endif()

include(FetchContent)
# CMake refuses to unpack an archive through a link, and on Windows the build folder is reached
# through one (flutter/app/build, scripts/apply.py): unpack in the folder it really is
file(REAL_PATH "${CMAKE_BINARY_DIR}" TL_REAL_BINARY_DIR)
set(FETCHCONTENT_BASE_DIR "${TL_REAL_BINARY_DIR}/_deps")
# the NDK has Vulkan's C headers only; llama.cpp's backend is written against the C++ ones
if(ANDROID AND GGML_VULKAN)
  FetchContent_Declare(vulkan_headers
    URL "https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/vulkan-sdk-1.4.335.0.tar.gz"
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
  FetchContent_Populate(vulkan_headers)
  include_directories(BEFORE "${vulkan_headers_SOURCE_DIR}/include")
  # the backend asks for this package by its config file, which only a Vulkan SDK install has
  FetchContent_Declare(spirv_headers
    URL "https://github.com/KhronosGroup/SPIRV-Headers/archive/refs/tags/vulkan-sdk-1.4.335.0.tar.gz"
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
  FetchContent_Populate(spirv_headers)
  include_directories(BEFORE "${spirv_headers_SOURCE_DIR}/include")
  file(WRITE "${CMAKE_BINARY_DIR}/spirv-headers-config/SPIRV-HeadersConfig.cmake"
    "if(NOT TARGET SPIRV-Headers::SPIRV-Headers)\n  add_library(SPIRV-Headers::SPIRV-Headers INTERFACE IMPORTED)\n  set_target_properties(SPIRV-Headers::SPIRV-Headers PROPERTIES INTERFACE_INCLUDE_DIRECTORIES \"${spirv_headers_SOURCE_DIR}/include\")\nendif()\n")
  set(SPIRV-Headers_DIR "${CMAKE_BINARY_DIR}/spirv-headers-config" CACHE PATH "" FORCE)
endif()
# Adreno: Qualcomm's own backend, where Vulkan loses the device. The headers and a loader to link
# against are built here; at run time libOpenCL.so is the phone's own (uses-native-library).
if(ANDROID AND TL_LLAMA_OPENCL)
  FetchContent_Declare(opencl_headers
    URL "https://github.com/KhronosGroup/OpenCL-Headers/archive/refs/tags/v2026.05.29.tar.gz"
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
  FetchContent_Populate(opencl_headers)
  FetchContent_Declare(opencl_loader
    URL "https://github.com/KhronosGroup/OpenCL-ICD-Loader/archive/refs/tags/v2026.05.29.tar.gz"
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
  FetchContent_Populate(opencl_loader)
  set(_cl_build "${CMAKE_BINARY_DIR}/opencl-loader")
  if(NOT EXISTS "${_cl_build}/libOpenCL.so")
    execute_process(COMMAND "${CMAKE_COMMAND}" -S "${opencl_loader_SOURCE_DIR}" -B "${_cl_build}" -G Ninja
                      "-DCMAKE_MAKE_PROGRAM=${CMAKE_MAKE_PROGRAM}" -DCMAKE_BUILD_TYPE=Release
                      "-DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}" "-DANDROID_ABI=${ANDROID_ABI}"
                      "-DANDROID_PLATFORM=${ANDROID_PLATFORM}" -DANDROID_STL=c++_shared -DBUILD_TESTING=OFF
                      "-DOPENCL_ICD_LOADER_HEADERS_DIR=${opencl_headers_SOURCE_DIR}"
                    RESULT_VARIABLE _cl_failed)
    if(NOT _cl_failed)
      execute_process(COMMAND "${CMAKE_COMMAND}" --build "${_cl_build}" --target OpenCL RESULT_VARIABLE _cl_failed)
    endif()
    if(_cl_failed)
      message(FATAL_ERROR "tl_llama: could not build the OpenCL loader")
    endif()
  endif()
  set(OpenCL_INCLUDE_DIR "${opencl_headers_SOURCE_DIR}" CACHE PATH "" FORCE)
  set(OpenCL_LIBRARY "${_cl_build}/libOpenCL.so" CACHE FILEPATH "" FORCE)
  set(GGML_OPENCL ON CACHE BOOL "" FORCE)
  set(GGML_OPENCL_USE_ADRENO_KERNELS ON CACHE BOOL "" FORCE)
  set(GGML_OPENCL_EMBED_KERNELS ON CACHE BOOL "" FORCE)
endif()
# Desktops: llama.cpp's own install rules have no place in the app's install (on Windows they cannot
# even use Flutter's prefix, on Linux they aim at /usr/local). Excluded, they do not run; the plugin
# bundles what it needs itself. Android has no install step.
set(_llama_exclude "")
if(NOT ANDROID)
  set(_llama_exclude EXCLUDE_FROM_ALL)
endif()
if(TL_LLAMA_SOURCE)
  FetchContent_Declare(llama SOURCE_DIR "${TL_LLAMA_SOURCE}" ${_llama_exclude})
else()
  FetchContent_Declare(llama
    URL "https://github.com/ggml-org/llama.cpp/archive/refs/tags/${TL_LLAMA_TAG}.tar.gz"
    PATCH_COMMAND "${CMAKE_COMMAND}" -DSRC=<SOURCE_DIR> -P "${CMAKE_CURRENT_LIST_DIR}/patch_opencl.cmake"
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    ${_llama_exclude})
endif()
# Windows on ARM: llama.cpp's CPU code needs clang there ("MSVC is not supported for ARM"),
# while Flutter builds every plugin with MSVC. llama.cpp is then built on its own with the
# clang-cl and Ninja that come with Visual Studio (same ABI as MSVC), and only the small C
# interface below is compiled by MSVC and linked against it.
if(WIN32 AND MSVC AND CMAKE_SYSTEM_PROCESSOR MATCHES "ARM64|aarch64|arm64" AND NOT CMAKE_C_COMPILER_ID STREQUAL "Clang")
  set(TL_LLAMA_CLANG ON)
endif()

if(NOT TL_LLAMA_CLANG)
  FetchContent_MakeAvailable(llama)

  add_library(tl_llama SHARED tl_llama.cpp)
  target_link_libraries(tl_llama PRIVATE llama mtmd ggml)
  if(ANDROID)
    target_link_libraries(tl_llama PRIVATE log)
  endif()
  target_compile_features(tl_llama PRIVATE cxx_std_17)
  target_compile_definitions(tl_llama PRIVATE TL_LLAMA_BUILD)
  set_target_properties(tl_llama PROPERTIES CXX_VISIBILITY_PRESET hidden)

  # every library the plugin needs at run time, for the platform CMake files to bundle: the
  # backends are separate modules (which CPU variants exist depends on the processor family)
  set(_libs tl_llama llama mtmd ggml ggml-base)
  foreach(b ggml-cpu ggml-vulkan ggml-opencl)
    if(TARGET ${b})
      list(APPEND _libs ${b})
    endif()
  endforeach()
  foreach(v x64 sse42 sandybridge haswell skylakex cannonlake cascadelake icelake cooperlake zen4 alderlake sapphirerapids
            armv8.0_1 armv8.2_1 armv8.2_2 armv8.2_3 armv8.6_1 armv9.2_1 armv9.2_2 android_armv8.0_1 android_armv8.2_1 android_armv8.2_2 android_armv8.6_1)
    if(TARGET ggml-cpu-${v})
      list(APPEND _libs ggml-cpu-${v})
    endif()
  endforeach()
  # the backends are loaded at run time, so nothing links them: without this an excluded one is not built
  set(_modules ${_libs})
  list(REMOVE_ITEM _modules tl_llama)
  add_dependencies(tl_llama ${_modules})
  set(TL_LLAMA_LIBRARIES ${_libs} PARENT_SCOPE)
  return()
endif()

# --- Windows on ARM: llama.cpp with clang-cl ---------------------------------------------------
# the source only (SOURCE_SUBDIR names no CMake project, so nothing is added here)
if(TL_LLAMA_SOURCE)
  set(_src "${TL_LLAMA_SOURCE}")
else()
  FetchContent_Declare(llama_arm
    URL "https://github.com/ggml-org/llama.cpp/archive/refs/tags/${TL_LLAMA_TAG}.tar.gz"
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    SOURCE_SUBDIR do-not-add)
  FetchContent_MakeAvailable(llama_arm)
  set(_src "${llama_arm_SOURCE_DIR}")
endif()
set(_vs "${CMAKE_GENERATOR_INSTANCE}")
set(_vcvars "${_vs}/VC/Auxiliary/Build/vcvarsarm64.bat")
set(_clang "${_vs}/VC/Tools/Llvm/ARM64/bin/clang-cl.exe")
set(_ninja "${_vs}/Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja/ninja.exe")
foreach(f _vcvars _clang _ninja)
  if(NOT EXISTS "${${f}}")
    message(FATAL_ERROR "tl_llama: ${${f}} is missing; Visual Studio needs its C++ Clang compiler and CMake tools")
  endif()
endforeach()
# Short: the Vulkan shader tool nests its own build deep inside, past cl.exe's path limit.
set(_bin "${CMAKE_BINARY_DIR}/lc")
set(_vk OFF)
if(TL_LLAMA_VULKAN AND DEFINED ENV{VULKAN_SDK})
  set(_vk ON)
endif()
set(_dlls llama ggml ggml-base ggml-cpu mtmd)
if(_vk)
  list(APPEND _dlls ggml-vulkan)
endif()
set(_products "")
foreach(d ${_dlls})
  list(APPEND _products "${_bin}/bin/${d}.dll")
endforeach()
set(_implibs "${_bin}/lib/llama.lib" "${_bin}/lib/ggml.lib" "${_bin}/lib/ggml-base.lib" "${_bin}/lib/mtmd.lib")
include(ExternalProject)
ExternalProject_Add(llama_clang
  SOURCE_DIR "${_src}"
  BINARY_DIR "${_bin}"
  CONFIGURE_COMMAND cmd /c call "${_vcvars}" >nul && "${CMAKE_COMMAND}" -S "${_src}" -B "${_bin}" -G Ninja
    "-DCMAKE_MAKE_PROGRAM=${_ninja}" "-DCMAKE_C_COMPILER=${_clang}" "-DCMAKE_CXX_COMPILER=${_clang}"
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DGGML_BACKEND_DL=ON -DGGML_NATIVE=OFF
    -DLLAMA_BUILD_COMMON=ON -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF
    -DLLAMA_BUILD_TOOLS=ON -DLLAMA_CURL=OFF -DGGML_VULKAN=${_vk}
    "-DCMAKE_RUNTIME_OUTPUT_DIRECTORY=${_bin}/bin" "-DCMAKE_LIBRARY_OUTPUT_DIRECTORY=${_bin}/bin"
    "-DCMAKE_ARCHIVE_OUTPUT_DIRECTORY=${_bin}/lib"
  BUILD_COMMAND cmd /c call "${_vcvars}" >nul && "${CMAKE_COMMAND}" --build "${_bin}" --target llama mtmd ggml-cpu
  INSTALL_COMMAND ""
  # its thousands of warnings go to log files; shown here only when it fails
  LOG_CONFIGURE ON LOG_BUILD ON LOG_MERGED_STDOUTERR ON LOG_OUTPUT_ON_FAILURE ON
  BUILD_BYPRODUCTS ${_products} ${_implibs})
if(_vk)
  # the Vulkan backend is a module of its own (loaded at run time): built with the rest
  ExternalProject_Add_Step(llama_clang vulkan
    COMMAND cmd /c call "${_vcvars}" >nul && "${CMAKE_COMMAND}" --build "${_bin}" --target ggml-vulkan
    DEPENDEES build LOG ON)
endif()

add_library(tl_llama SHARED tl_llama.cpp)
add_dependencies(tl_llama llama_clang)
target_include_directories(tl_llama PRIVATE "${_src}/include" "${_src}/ggml/include" "${_src}/tools/mtmd")
target_link_libraries(tl_llama PRIVATE ${_implibs})
target_compile_features(tl_llama PRIVATE cxx_std_17)
target_compile_definitions(tl_llama PRIVATE TL_LLAMA_BUILD)
# the platform CMake file bundles files, not targets, here
set(TL_LLAMA_LIBRARIES tl_llama PARENT_SCOPE)
set(TL_LLAMA_FILES ${_products} PARENT_SCOPE)
