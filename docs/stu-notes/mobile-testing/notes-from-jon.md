export NDK_HOME=home/fu/android-ndk-xxx and ANDROID_HOME=/home/fu/Android/Sdk
go to dioxus repository, examples, mobile_demo
`cargo android init`
`cargo android build`
`cargo android run`

create a machine like this:
`cargo android open`
create a new device target - a pixel6 with aarch64
- have to do this on a mac :(


wait a sec
`cargo android apk build --release`
needs java17
export PATH=/home/fu/android-studio/jbr/bin:$PATH

`cargo android run --release`
nope. `cargo android run` works though. 

`find | grep apk`
`adb install ......./app-universal-debug.apk`

`adb devices`
`adb -s <device name> install <path-to-apk>`

./emulator -list-avds
Pixel_3a_API_34_extension_level_7_x86_64
fu@pop-os:~/Android/Sdk/emulator$ ./emulator -avd Pixel_3a_API_34_extension_level_7_x86_64 -netdelay none -netspeed full


`cargo android apk build aarch64`
