# libarca_whisper: whisper.cpp and ggml linked statically behind the small C
# interface in arca_whisper.h. Used by the Linux runner and the Android app.
cmake_minimum_required(VERSION 3.14)
project(arca_whisper C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Speech recognition is unusable without optimization, so build it
# optimized even inside a debug build of the app.
set(CMAKE_C_FLAGS_DEBUG "-O2 -g0")
set(CMAKE_CXX_FLAGS_DEBUG "-O2 -g0")

# Portable CPU code: no -march=native, so the library runs on other
# machines than the one that built it (on x86-64 this keeps AVX2 and FMA).
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)

add_subdirectory(${CMAKE_CURRENT_LIST_DIR}/../../third_party/whisper.cpp
                 ${CMAKE_CURRENT_BINARY_DIR}/whisper.cpp EXCLUDE_FROM_ALL)

add_library(arca_whisper SHARED ${CMAKE_CURRENT_LIST_DIR}/arca_whisper.cpp)
target_link_libraries(arca_whisper PRIVATE whisper)
set_target_properties(arca_whisper PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(arca_whisper PRIVATE ARCA_WHISPER_BUILD)
target_link_options(arca_whisper PRIVATE -Wl,--exclude-libs,ALL)
