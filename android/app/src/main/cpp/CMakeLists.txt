# voicefx for Android (native/voicefx): RNNoise and the gain, run in flutter_webrtc's capture hook (VoiceFx.kt).
cmake_minimum_required(VERSION 3.18)
project(voicefx C CXX)
set(VFX ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../native/voicefx)
file(GLOB RNNOISE ${VFX}/rnnoise/src/*.c)
add_library(voicefx SHARED ${VFX}/voicefx.c ${VFX}/stretch.cpp ${RNNOISE} voicefx_jni.c)
target_include_directories(voicefx PRIVATE ${VFX}/include ${VFX}/rnnoise/include ${VFX}/rnnoise/src)
target_include_directories(voicefx PRIVATE ${VFX})
# C11 for voicefx and RNNoise, C++14 for Signalsmith Stretch (stretch.cpp).
target_compile_options(voicefx PRIVATE -O2 -fvisibility=hidden $<$<COMPILE_LANGUAGE:C>:-std=c11> $<$<COMPILE_LANGUAGE:CXX>:-std=c++14>)
target_link_libraries(voicefx m log)
