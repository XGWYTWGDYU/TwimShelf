cmake_minimum_required(VERSION 3.21)
set(PROJECT_NAME "tl_llama")
project(${PROJECT_NAME} LANGUAGES C CXX)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

set(tl_llama_bundled_libraries "" PARENT_SCOPE)
set(_files "")
foreach(t ${TL_LLAMA_LIBRARIES})
  list(APPEND _files $<TARGET_FILE:${t}>)
endforeach()
# Windows on ARM builds llama.cpp separately (src/CMakeLists.txt): its libraries are files
list(APPEND _files ${TL_LLAMA_FILES})
set(tl_llama_bundled_libraries ${_files} PARENT_SCOPE)
