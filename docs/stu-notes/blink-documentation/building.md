# building libaom
- install header files in /usr/local/include - cmake, make, make install will put them there
- then use the precompiled library option

building for arm
- install cargo-ndk
- install android ndk and set root of that folder to ANDROID_NDK_HOME

# build extensions/warp-blink-wrtc: this works
cd extensions/warp-blink-wrtc
export ANDROID_NDK_HOME=/home/fu/android-ndk-rc25c
export CMAKE_TOOLCHAIN_FILE=/home/fu/android-ndk-r25c/build/cmake/android.toolchain.cmake
cargo ndk -t arm64-v8a build
cargo ndk -t armeabi-v7a build
cargo ndk -t armeabi-v7a -t arm64-v8a build



- opus fails to build within build script. 
    - cross compile opus for target platform and set LIBOPUS_LIB_DIR or LIBOPUS_STATIC accordingly
        - opus repository: https://github.com/xiph/opus/tree/7b05f44f4baadf34d8d1073f4ff69f1806d5cdb4
        - how to set the cmake toolchain file https://cmake.org/cmake/help/book/mastering-cmake/chapter/Cross%20Compiling%20With%20CMake.html
        - the android ndk has a cmake toolchain already. just need to `export ANDROID_ABI=<desired platform>`. in this case it was `armeabi-v7a`
        - `cmake -DCMAKE_TOOLCHAIN_FILE=/home/fu/android-ndk-r25c/build/cmake/android.toolchain.cmake`
        - `make`
        - got a `libopus.a` out of it!. use `LIBOPUS_STATIC` to find it...

export TOOLCHAIN=/home/fu/android-ndk-r25c/toolchains/llvm/prebuilt/linux-x86_64
export CC=$TOOLCHAIN/bin/armv7a-linux-androideabi33-clang
export CXX=$TOOLCHAIN/bin/armv7a-linux-androideabi33-clang++
export AR=$TOOLCHAIN/bin/llvm-ar
export LD=$TOOLCHAIN/bin/ld
cargo build --target armv7-linux-androideabi


`cargo ndk -t armeabi-v7a build`
export CMAKE_TOOLCHAIN_FILE=/home/fu/android-ndk-r25c/build/cmake/android.toolchain.cmake

# build audiopus-sys: this works
git submodule init
git submodule update
export ANDROID_NDK_HOME=/home/fu/android-ndk-rc25c
export CMAKE_TOOLCHAIN_FILE=/home/fu/android-ndk-r25c/build/cmake/android.toolchain.cmake
cargo ndk -t armeabi-v7a build

# build extensions/warp-blink-wrtc: this works
cd extensions/warp-blink-wrtc
export ANDROID_NDK_HOME=~/android-ndk-rc25c
export CMAKE_TOOLCHAIN_FILE=~/android-ndk-r25c/build/cmake/android.toolchain.cmake
cargo ndk -t armeabi-v7a build

linker problems...
.cargo/config file? 

put this in the cargo.toml
[target.arm-linux-androideabi]
linker = "arm-linux-androideabi-gcc"


#####
building using tauri-mobile
happened after i installed tauri-mobile (cargo install --git https://github.com/tauri-apps/tauri-mobile), android studio, and set env vars for NDK_HOME (/home/fu/android-ndk-xxxx) and ANDROID_HOME  (/home/fu/android-studio)
[4:58 PM]
nvm, cargo mobile init made it build. waiting...
[4:58 PM]
cargo android build just worked


##
readelf -h libwarp.a | grep 'Class\|\File\|Machine'


cargo build --target aarch64-linux-android

cargo install cross
cross build --target aarch64-linux-android

export PATH=$PATH:/home/fu/android-ndk-r25c/toolchains/llvm/prebuilt/linux-x86_64/bin
export CC=aarch64-linux-android33-clang
export CXX=aarch64-linux-android33-clang++
export AR=llvm-ar
~/.cargo/bin/cargo build --target aarch64-linux-android


# try again
build the opus c code
./autogen.sh
export PATH=/home/fu/android-ndk-r25c/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH
export CC=aarch64-linux-android33-clang
export CXX=aarch64-linux-android33-clang++
export AR=llvm-ar
export LD=llvm-ld
./configure --host=aarch64-linux-android
make

puts it in .libs

## building the infernal audiopus_sys again
export OPUS_LIB_DIR=/home/fu/GitRepos/opus/.libs
cargo build --target aarch64-linux-android --verbose

## with warp, blake3 won't build...

- try using `cross` https://kerkour.com/rust-cross-compilation

# trying this 
https://pagefault.blog/2018/07/04/embedded-development-with-yocto-and-rust/