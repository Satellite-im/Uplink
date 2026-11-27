// swift-tools-version: 5.9
// voicefx as a Swift package, for the Mac and iPhone apps (macos/Runner/VoiceFx.swift, ios/Runner/VoiceFx.swift): RNNoise and the microphone's gain, in C,
// the packing of a circle's music (music_pack.c), and DeepFilterNet where deepfilter/build.sh has built it (tool/release-mac.mjs does): without it, RNNoise alone.
import Foundation
import PackageDescription

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let deepFilter = FileManager.default.fileExists(atPath: here + "/deepfilter/build/VoiceFxDeepFilter.xcframework")

var targets: [Target] = [
    .target(
        name: "VoiceFxC",
        dependencies: deepFilter ? ["VoiceFxDeepFilter"] : [],
        path: ".",
        exclude: ["test", "README.md", "rnnoise/COPYING", "deepfilter", "signalsmith/LICENSE-stretch.txt", "signalsmith/LICENSE-linear.txt", "signalsmith/README.md"],
        sources: ["voicefx.c", "music_pack.c", "stretch.cpp", "rnnoise/src"],
        publicHeadersPath: "include",
        cSettings: [
            .headerSearchPath("rnnoise/include"),
            .headerSearchPath("rnnoise/src"),
            .unsafeFlags(["-O2"]),
        ] + (deepFilter ? [.define("VOICEFX_WITH_DEEPFILTER")] : []),
        cxxSettings: [.headerSearchPath("."), .unsafeFlags(["-O2"])],
        linkerSettings: deepFilter ? [.linkedFramework("Security"), .linkedFramework("CoreFoundation")] : []
    )
]
if deepFilter {
    targets.append(.binaryTarget(name: "VoiceFxDeepFilter", path: "deepfilter/build/VoiceFxDeepFilter.xcframework"))
}

let package = Package(
    name: "VoiceFx",
    platforms: [.macOS("10.15"), .iOS("16.0")],
    products: [.library(name: "VoiceFxC", targets: ["VoiceFxC"])],
    targets: targets,
    cxxLanguageStandard: .cxx14
)
