export ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/25.2.9519653
export ANDROID_NDK=$ANDROID_NDK_HOME
export ANDROID_NDK_ROOT=$ANDROID_NDK_HOME
export ANDROID_NDK_PLATFORM=android-33
export ANDROID_NDK_TOOLCHAIN_VERSION=clang
# export ANDROID_ABI=arm64-v8a
export ANDROID_TOOLCHAIN_NAME=aarch64-linux-android-clang
export ANDROID_STL=c++_static
export ANDROID_NATIVE_API_LEVEL=33
export ANDROID_TOOLCHAIN=aarch64-linux-android-clang
export ANDROID_ARM_MODE=arm
# export ANDROID_ARM_NEON=TRUE
export CMAKE_TOOLCHAIN_FILE=$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake

# export ANDROID_NDK_HOME=$ANROID_HOME/ndk/25.2.9519653
# export CMAKE_TOOLCHAIN_FILE=$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake
cargo android run

# cargo android run
