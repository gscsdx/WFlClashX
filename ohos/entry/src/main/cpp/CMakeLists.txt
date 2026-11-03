# NAPI bridge to the Go clash core.
#
# libclash_core.so (mihomo, product of core/build_ohos.sh) IS linked here as a
# DT_NEEDED dependency: the Go c-shared runtime uses initial-exec TLS, which
# musl only grants to libraries loaded at process startup. dlopen()ing it at
# runtime fails with "initial-exec TLS resolves to dynamic definition". The
# link records a SONAME-based DT_NEEDED, so clash_bridge.cpp's dlopen() simply
# binds to the already-loaded instance.
cmake_minimum_required(VERSION 3.5.0)
project(clash_bridge)

set(CMAKE_CXX_STANDARD 17)

add_library(clash_bridge SHARED clash_bridge.cpp)

target_include_directories(clash_bridge PRIVATE
  ${OHOS_STL_INCLUDE}
)

# Prebuilt Go core (entry/libs/arm64-v8a/libclash_core.so, SONAME
# libclash_core.so). Linked by path; the SONAME keeps DT_NEEDED resolvable.
target_link_libraries(clash_bridge PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/arm64-v8a/libclash_core.so
)

target_link_libraries(clash_bridge PUBLIC
  libace_napi.z.so
  libhilog_ndk.z.so
  libdl.so
)
