# Keep generated registration aligned with this runner's application ID.
file(READ "${DESKTOP_FILE}" contents)
string(REGEX REPLACE "StartupWMClass=[^\n]*" "StartupWMClass=${APP_ID}" contents "${contents}")
if(NOT contents MATCHES "(^|\n)Icon=")
  string(APPEND contents "Icon=${APP_ICON}\n")
endif()
# "open with" (the share setting in config.yaml) off: no file types offered
if(SHARE STREQUAL "OFF")
  string(REGEX REPLACE "MimeType=[^\n]*\n" "" contents "${contents}")
endif()
file(WRITE "${DESKTOP_FILE}" "${contents}")
