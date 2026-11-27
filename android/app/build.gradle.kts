import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

/*
 * THE RELEASE KEY. Android installs an update only over an app signed with the same certificate, so every release is
 * signed with one key kept outside the repository: ~/.config/ghostmessaging/signing.properties (or the file
 * $GHOSTMESSAGING_SIGNING names) with storeFile, storePassword, keyAlias and keyPassword. tool/release.mjs makes it
 * the first time. Without it a release build is signed with this machine's debug key, and tool/release.mjs refuses to
 * publish that.
 */
val signingFile = file(System.getenv("GHOSTMESSAGING_SIGNING") ?: "${System.getProperty("user.home")}/.config/ghostmessaging/signing.properties")
val signing = Properties().apply { if (signingFile.exists()) signingFile.inputStream().use { load(it) } }

android {
    namespace = "com.infamousvague.ghostmessaging"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.infamousvague.ghostmessaging"
        // 26: Notification channels and MessagingStyle without the support library. 29: RoleManager for the SMS role.
        minSdk = 29
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // arm64 only: the phones this is for.
        ndk { abiFilters += listOf("arm64-v8a") }
    }

    // The Google Messages sidecar (libgmsidecar.so, an executable): unpacked on install, so the app may run it from
    // its native library folder (GmWeb.kt).
    // Only arm64's native libraries: the Flutter engine is built for arm64 alone (abiFilters above), so the app can't
    // start on any other kind of phone, yet some libraries brought their armeabi-v7a and x86_64 copies along anyway
    // (libmpv, WebRTC, translation, voice effects: about 85 MB unpacked that no phone could use; Matt, 2026-11-18,
    // "I am okay with the trim").
    packaging { jniLibs { useLegacyPackaging = true; excludes += listOf("lib/armeabi-v7a/**", "lib/armeabi/**", "lib/x86/**", "lib/x86_64/**") } }

    // TDLib for the Telegram inbox (lib/inbox/telegram.dart), built by tool/build-tdlib.sh android into the app's
    // build folder: taken in where it is there; without it, Telegram says it isn't in this build.
    sourceSets { getByName("main") { jniLibs.srcDir("../../build/tdlib/android") } }

    // The direct network's core (native/p2p; lib/net/p2p/node_ffi.dart, P2pCore.kt), built by tool/build-p2p.sh android
    // into the app's build folder in the same way: taken in where it is there; without it the app has no direct route
    // and is otherwise the same.
    sourceSets { getByName("main") { jniLibs.srcDir("../../build/p2p/android") } }

    // voicefx (native/voicefx): RNNoise and the microphone's gain, for calls (VoiceFx.kt).
    externalNativeBuild {
        cmake { path = file("src/main/cpp/CMakeLists.txt") }
    }

    signingConfigs {
        if (signing.getProperty("storeFile") != null) {
            create("release") {
                storeFile = file(signing.getProperty("storeFile"))
                storePassword = signing.getProperty("storePassword")
                keyAlias = signing.getProperty("keyAlias")
                keyPassword = signing.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // The messages live in Android's own SMS database, not the app's, so reinstalling over a differently
            // signed build (a debug-key build from a machine without the release key) loses nothing.
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // WebRTC's classes, for VoiceFx.kt's hook into flutter_webrtc's capture processing: compiled against only, since
    // flutter_webrtc brings the library itself. The same version flutter_webrtc 1.6.3 uses.
    compileOnly("io.github.webrtc-sdk:android:150.7871.04")
    // Reads the QR code a computer shows to pair with (ScanActivity.kt): on the phone, with nothing from Google Play.
    implementation("com.google.zxing:core:3.5.3")
    // Summaries of unread conversations on the phone itself (Summaries.kt; Matt, 2026-11-14: "Use a local AI to
    // summarize unread message conversations like apple does"): Android's own on-device model (Gemini Nano, through
    // AICore) by ML Kit's GenAI Summarization API, in beta. Nothing is sent anywhere; a phone without it says so.
    implementation("com.google.mlkit:genai-summarization:1.0.0-beta1")
    // Texts in another language translated on the phone itself (Translate.kt; Matt, 2026-11-17: "add a translate plugin
    // which can automatically translate texts when detected from another language"): ML Kit's on-device Translation, a
    // model of about 30 MB per language fetched once, and its Language Identification with the model inside the app (not
    // Play's), so nothing of a text leaves the phone.
    // Replies to choose from that read the conversation (SmartReplies.kt; Matt, 2026-11-26: "add more intelligent auto
    // replies using a very lightweight local AI"): ML Kit's Smart Reply, its small model inside the app, on every phone.
    implementation("com.google.mlkit:smart-reply:17.0.4")
    implementation("com.google.mlkit:translate:17.0.3")
    implementation("com.google.mlkit:language-id:17.0.6")
    testImplementation("junit:junit:4.13.2")
    // Android's own org.json is a stub on the JVM: the desktop link's tests (DeskSessionTest) need a real one.
    testImplementation("org.json:json:20240303")
}
