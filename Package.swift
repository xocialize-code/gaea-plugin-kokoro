// swift-tools-version: 6.2
import PackageDescription

// gaea-plugin-kokoro: Kokoro-82M (Apache-2.0 weights) as a Gaea plugin, the first on MES Audio 0.1. One worker
// executable built on GaeaPluginKit over mlx-kokoro-tts-swift, packaged as a signed .gaeaplugin by
// scripts/build-plugin.sh.
//
// kokoro-inproc is not part of the plugin: it runs the same package in-process through MLXServeEngine, with the same
// dependency resolution and the same text plan, as the reference a run through Gaea is compared against.
//
// GAEA_PLUGIN_KIT_PATH points the kit at a local checkout while you work on both.
let kitPath = Context.environment["GAEA_PLUGIN_KIT_PATH"]

let package = Package(
    name: "gaea-plugin-kokoro",
    platforms: [.macOS(.v26)], // mlx-engine-swift's MLXToolKit requires macOS 26
    dependencies: [
        kitPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.7.1"),
        .package(url: "https://github.com/xocialize/mlx-kokoro-tts-swift.git", exact: "0.5.0"),
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.73.0"),
        // MLX's random state: Kokoro's sine source draws noise from it, so a seeded run seeds it first.
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.33.0"),
    ],
    targets: [
        .target(
            name: "KokoroPlugin",
            dependencies: [
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "MLXKokoroTTS", package: "mlx-kokoro-tts-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
        .executableTarget(
            name: "gaea-kokoro-worker",
            dependencies: [
                "KokoroPlugin",
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
            ]
        ),
        .executableTarget(
            name: "kokoro-inproc",
            dependencies: [
                "KokoroPlugin",
                .product(name: "MLXKokoroTTS", package: "mlx-kokoro-tts-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "KokoroPluginTests", dependencies: ["KokoroPlugin"]),
    ]
)
