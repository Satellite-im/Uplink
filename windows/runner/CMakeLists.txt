cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES C CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "voice_fx.cpp"
  "call_recorder.cpp"
  "call_video.cpp"
  "speech.cpp"
  "main_thread.cpp"
  "sounds.cpp"
  "clipboard.cpp"
  "desk_sound.cpp"
  "ducking.cpp"
  "links.cpp"
  "splash.cpp"
  "spotify.cpp"
  "spotify_sound.cpp"
  "music_sink.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
# PlaySound, for the interface sounds (sounds.cpp).
target_link_libraries(${BINARY_NAME} PRIVATE "winmm.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
# Recording a call (call_recorder.cpp): Media Foundation's AAC encoder and file writer, and libwebrtc itself, whose
# track kind comes back as its own string type (flutter_webrtc links it privately, so the app links it too).
# Live captions and Scribe (speech.cpp): SAPI's recogniser, Media Foundation to read a recording's track.
target_link_libraries(${BINARY_NAME} PRIVATE "mfplat.lib" "mfreadwrite.lib" "mfuuid.lib" "sapi.lib" "shlwapi.lib" "ole32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}/flutter/ephemeral/.plugin_symlinks/flutter_webrtc/third_party/libwebrtc/lib/libwebrtc.dll.lib")

# A circle's music played here without loss (music_sink.cpp) needs no more of Windows than its sound below does.
# Spotify in a circle's calls: Windows' media controls (spotify.cpp, C++/WinRT from the Windows SDK), and the sound of the
# Spotify app alone (spotify_sound.cpp), as a track of flutter_webrtc's, whose headers are read as flutter_webrtc itself
# reads them (RTC_DESKTOP_DEVICE: the file says why).
target_link_libraries(${BINARY_NAME} PRIVATE "runtimeobject.lib" "oleaut32.lib" "mmdevapi.lib" "avrt.lib" "shell32.lib")
set_source_files_properties("spotify_sound.cpp" PROPERTIES COMPILE_DEFINITIONS "RTC_DESKTOP_DEVICE")
# C++/WinRT's headers take C++20's coroutines, or in C++17 the experimental ones Visual Studio refuses from 2026 on.
set_source_files_properties("spotify.cpp" PROPERTIES COMPILE_OPTIONS "/std:c++20")

# voicefx (native/voicefx): RNNoise and the microphone's gain, for calls (voice_fx.cpp), built as C into the app.
set(VOICEFX "${CMAKE_SOURCE_DIR}/../native/voicefx")
file(GLOB VOICEFX_RNNOISE "${VOICEFX}/rnnoise/src/*.c")
add_library(voicefx STATIC "${VOICEFX}/voicefx.c" "${VOICEFX}/music_pack.c" "${VOICEFX}/stretch.cpp" ${VOICEFX_RNNOISE})
target_include_directories(voicefx PUBLIC "${VOICEFX}/include" PRIVATE "${VOICEFX}" "${VOICEFX}/rnnoise/include" "${VOICEFX}/rnnoise/src")
# Signalsmith Stretch (stretch.cpp) is C++.
set_source_files_properties("${VOICEFX}/stretch.cpp" PROPERTIES COMPILE_OPTIONS "/std:c++17;/EHsc")
target_compile_definitions(voicefx PRIVATE _USE_MATH_DEFINES _CRT_SECURE_NO_WARNINGS)
target_link_libraries(${BINARY_NAME} PRIVATE voicefx)
# DeepFilterNet, where the build made it (the workflow's "Build DeepFilterNet"): Rust's static library and what Rust's
# standard library asks of Windows.
set(VOICEFX_DF "${VOICEFX}/deepfilter/target/release/voicefx_deepfilter.lib")
if(EXISTS "${VOICEFX_DF}")
  target_compile_definitions(voicefx PRIVATE VOICEFX_WITH_DEEPFILTER)
  target_link_libraries(voicefx PUBLIC "${VOICEFX_DF}" advapi32 bcrypt kernel32 ntdll userenv ws2_32 synchronization)
  message(STATUS "voicefx: with DeepFilterNet")
else()
  message(STATUS "voicefx: RNNoise alone (no ${VOICEFX_DF})")
endif()

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
