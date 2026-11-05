# Windows on ARM: media_kit only ships x64 libmpv and ANGLE. Its CMake skips its own
# extraction when ${CMAKE_BINARY_DIR}/libmpv and /ANGLE already hold files, so this fills
# them with ARM64 ones first:
#   libmpv  the aarch64 build from the builder media_kit's x64 one comes from
#   ANGLE   the copy in the WebView2 runtime (part of Windows 11), with headers from
#           media_kit's own ANGLE archive and import libraries made from the DLLs
# Included before generated_plugins.cmake; tl_media_kit_arm64_bundle() runs after it.

set(_mpv_name "mpv-dev-aarch64-20261021-git-e471496c56.7z")
set(_mpv_url "https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20261021/${_mpv_name}")
set(_mpv_sha256 "015F133399B3525021B6D937CF54ACE2761D4F70224D5E62F5DF24191B28F398")
# the same archive and hash media_kit's CMake uses, so it finds it in place and skips it
set(_angle_url "https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z")
set(_angle_md5 "e866f13e8d552348058afaafe869b1ed")

set(_mpv "${CMAKE_BINARY_DIR}/libmpv")
set(_angle "${CMAKE_BINARY_DIR}/ANGLE")

# .arm64 marks folders filled here (an earlier x64 build may have left its own)
if(NOT EXISTS "${_mpv}/.arm64")
  file(DOWNLOAD "${_mpv_url}" "${CMAKE_BINARY_DIR}/${_mpv_name}"
    EXPECTED_HASH SHA256=${_mpv_sha256} SHOW_PROGRESS)
  file(REMOVE_RECURSE "${_mpv}")
  # Windows' own tar: CMake's reader stops at this archive's ARM64 filter. -P lets tar write
  # through the build folder's link into the cache (the archive is pinned above).
  file(MAKE_DIRECTORY "${_mpv}")
  execute_process(COMMAND "$ENV{SystemRoot}/System32/tar.exe" -xPf "${CMAKE_BINARY_DIR}/${_mpv_name}"
    WORKING_DIRECTORY "${_mpv}" COMMAND_ERROR_IS_FATAL ANY)
  # media_kit expects the headers directly in include/
  file(GLOB _headers "${_mpv}/include/mpv/*.h")
  file(COPY ${_headers} DESTINATION "${_mpv}/include")
  file(REMOVE_RECURSE "${_mpv}/include/mpv")
  file(WRITE "${_mpv}/.arm64" "")
endif()

if(NOT EXISTS "${_angle}/.arm64")
  set(_pf "ProgramFiles(x86)")
  file(TO_CMAKE_PATH "$ENV{${_pf}}" _pf)
  file(GLOB _webview "${_pf}/Microsoft/EdgeWebView/Application/*/libGLESv2.dll")
  if(NOT _webview)
    message(FATAL_ERROR "Video on Windows ARM needs the WebView2 runtime's ANGLE (libGLESv2.dll); install the Microsoft Edge WebView2 Runtime")
  endif()
  list(SORT _webview)
  list(GET _webview -1 _webview)
  get_filename_component(_webview "${_webview}" DIRECTORY)
  file(DOWNLOAD "${_angle_url}" "${CMAKE_BINARY_DIR}/ANGLE.7z" EXPECTED_HASH MD5=${_angle_md5})
  file(REMOVE_RECURSE "${_angle}")
  file(ARCHIVE_EXTRACT INPUT "${CMAKE_BINARY_DIR}/ANGLE.7z" DESTINATION "${_angle}" PATTERNS "include/*")
  foreach(f libEGL libGLESv2 d3dcompiler_47 vk_swiftshader vulkan-1)
    file(COPY "${_webview}/${f}.dll" DESTINATION "${_angle}")
  endforeach()
  # import libraries from the DLLs' export tables
  get_filename_component(_tools "${CMAKE_LINKER}" DIRECTORY)
  file(MAKE_DIRECTORY "${_angle}/lib")
  foreach(f libEGL libGLESv2)
    execute_process(COMMAND "${_tools}/dumpbin.exe" /nologo /exports "${_angle}/${f}.dll"
      OUTPUT_VARIABLE _out COMMAND_ERROR_IS_FATAL ANY)
    set(_def "LIBRARY ${f}.dll\nEXPORTS\n")
    string(REGEX MATCHALL "\n +[0-9]+ +[0-9A-F]+ +[0-9A-F]+ +[A-Za-z_][A-Za-z0-9_@]*" _rows "${_out}")
    foreach(r ${_rows})
      string(REGEX REPLACE ".* ([A-Za-z_][A-Za-z0-9_@]*)$" "\\1" _sym "${r}")
      string(APPEND _def "  ${_sym}\n")
    endforeach()
    file(WRITE "${_angle}/lib/${f}.def" "${_def}")
    execute_process(COMMAND "${_tools}/lib.exe" /nologo /machine:arm64
      "/def:${_angle}/lib/${f}.def" "/out:${_angle}/lib/${f}.dll.lib" COMMAND_ERROR_IS_FATAL ANY)
  endforeach()
  file(WRITE "${_angle}/.arm64" "")
endif()

# media_kit also bundles zlib.dll, which only its own ANGLE build needs
function(tl_media_kit_arm64_bundle)
  list(FILTER PLUGIN_BUNDLED_LIBRARIES EXCLUDE REGEX "/ANGLE/zlib\\.dll$")
  set(PLUGIN_BUNDLED_LIBRARIES "${PLUGIN_BUNDLED_LIBRARIES}" PARENT_SCOPE)
endfunction()
