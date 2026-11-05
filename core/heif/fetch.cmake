# Fetches the sources of the HEIC/AVIF decoders, each checked against its hash.
# cmake -DDEST=<dir> -P fetch.cmake
set(parts
  "libde265-1.1.3|https://github.com/strukturag/libde265/releases/download/v1.1.3/libde265-1.1.3.tar.gz|554228bd17788c99a7e63b37ab5634722190e6e2bf60c1dcb01cef328e133905"
  "dav1d-1.5.3|https://downloads.videolan.org/pub/videolan/dav1d/1.5.3/dav1d-1.5.3.tar.xz|732010aa5ef461fa93355ed2c6c5fedb48ddc4b74e697eaabe8907eaeb943011"
  "libheif-1.23.7|https://github.com/strukturag/libheif/releases/download/v1.23.7/libheif-1.23.7.tar.gz|f7483e818503ea6224c8863e4a56ac02c7089021a98472c811c12aa19faf2475")
foreach(part IN LISTS parts)
  string(REPLACE "|" ";" fields "${part}")
  list(GET fields 0 name)
  list(GET fields 1 url)
  list(GET fields 2 hash)
  if(EXISTS "${DEST}/${name}/.complete")
    continue()
  endif()
  get_filename_component(file "${url}" NAME)
  file(DOWNLOAD "${url}" "${DEST}/${file}" EXPECTED_HASH SHA256=${hash} TLS_VERIFY ON STATUS status)
  list(GET status 0 code)
  if(NOT code EQUAL 0)
    message(FATAL_ERROR "Downloading ${url} failed: ${status}")
  endif()
  file(REMOVE_RECURSE "${DEST}/${name}.tmp" "${DEST}/${name}")
  file(ARCHIVE_EXTRACT INPUT "${DEST}/${file}" DESTINATION "${DEST}/${name}.tmp")
  file(RENAME "${DEST}/${name}.tmp/${name}" "${DEST}/${name}")
  file(REMOVE_RECURSE "${DEST}/${name}.tmp")
  file(TOUCH "${DEST}/${name}/.complete")
endforeach()
